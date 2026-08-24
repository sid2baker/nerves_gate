defmodule NervesGate.DeviceState.Signal.Changing do
  @moduledoc "Raw condition indicating that a complete settings candidate is active."
  def description, do: "Configuration change in progress"
end

defmodule NervesGate.DeviceState.Alarms do
  @moduledoc "Owns DeviceState signals used to inhibit expected operational alarms."

  alias NervesGate.Alarms
  alias NervesGate.DeviceState.Signal

  def managed_alarms, do: []
  def public_alarms, do: []
  def alarm_levels, do: %{Signal.Changing => :debug}
  def remedies, do: []

  @spec changing(boolean()) :: :ok
  def changing(active) do
    Alarms.report_sync(Signal.Changing, active, Signal.Changing.description())
  end
end

defmodule NervesGate.DeviceState.Server do
  @moduledoc """
  Owns this gateway's private settings machinery and canonical public data.

  The server is the sole writer and operation sequencer for this physical
  gateway. Only its secret-free `DeviceState.Data` is sent to joined peer
  clients. Firmware-slot settings, candidates, credentials, timers, and effect
  metadata remain local process state.
  """

  use GenServer

  alias NervesGate.Alarms
  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.Commissioning.Alarms, as: CommissioningAlarms
  alias NervesGate.DeviceState.Alarms, as: DeviceStateAlarms
  alias NervesGate.DeviceState.Data
  alias NervesGate.Gateway.Effects
  alias NervesGate.Gateway.Persistence
  alias NervesGate.Gateway.Settings
  alias NervesGate.Identity
  alias NervesGate.Internet.Config
  alias NervesGate.Internet.Monitor
  alias NervesGate.SSH
  alias NervesGate.Storage
  alias NervesGate.Storage.Alarms, as: StorageAlarms
  alias NervesGate.SubnetRouter.Alarms, as: SubnetRouterAlarms
  alias NervesGate.Tailnet.Observer

  @slots ["a", "b"]
  @default_timeout :timer.minutes(1)

  defstruct [
    :data,
    :boot_id,
    :root,
    :firmware,
    :current,
    :pending,
    :timer,
    :ops,
    :last_error,
    revision: 0,
    clients: %{},
    keep_local_access: false
  ]

  @type snapshot :: %{
          boot_id: String.t(),
          revision: non_neg_integer(),
          data: Data.t()
        }

  @type observation :: %{
          boot_id: String.t(),
          revision: non_neg_integer(),
          data: Data.t(),
          configuration: map()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec data(GenServer.server()) :: Data.t()
  def data(server \\ __MODULE__), do: GenServer.call(server, :data)

  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @spec join(pid(), GenServer.server()) :: {:ok, snapshot()}
  def join(client, server \\ __MODULE__) when is_pid(client) do
    GenServer.call(server, {:join, client})
  end

  @doc "Returns an atomic public observation of configuration and canonical device data."
  @spec observation(GenServer.server()) :: observation()
  def observation(server \\ __MODULE__), do: GenServer.call(server, :observation)

  @doc false
  @spec apply_operation(Data.operation(), GenServer.server()) :: :ok | :error
  def apply_operation(operation, server \\ __MODULE__) do
    GenServer.call(server, {:apply_operation, operation})
  end

  @spec configured?(GenServer.server()) :: boolean()
  def configured?(server \\ __MODULE__), do: GenServer.call(server, :configured?)

  @doc false
  @spec current(GenServer.server()) :: map()
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @spec configuration(GenServer.server()) :: map()
  def configuration(server \\ __MODULE__), do: GenServer.call(server, :configuration)

  @spec stage_internet(map(), String.t(), pos_integer() | nil, GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def stage_internet(
        params,
        source_connection,
        timeout \\ @default_timeout,
        server \\ __MODULE__
      )
      when is_map(params) and is_binary(source_connection) and
             (is_nil(timeout) or (is_integer(timeout) and timeout > 0)) do
    GenServer.call(server, {:stage_internet, params, source_connection, timeout}, 45_000)
  end

  @spec update_internet(String.t(), map(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def update_internet(id, params, server \\ __MODULE__)
      when is_binary(id) and is_map(params) do
    GenServer.call(server, {:update_internet, id, params}, 45_000)
  end

  @spec stage_tailnet(String.t(), map(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def stage_tailnet(id, params, server \\ __MODULE__)
      when is_binary(id) and is_map(params) do
    GenServer.call(server, {:stage_tailnet, id, params}, 45_000)
  end

  @spec stage_cluster(String.t(), map(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def stage_cluster(id, params, server \\ __MODULE__)
      when is_binary(id) and is_map(params) do
    GenServer.call(server, {:stage_cluster, id, params}, 45_000)
  end

  @type acceptance_connection :: %{id: String.t(), tailnet?: boolean()}

  @spec confirm(String.t(), acceptance_connection(), GenServer.server()) ::
          :ok | {:error, term()}
  def confirm(id, connection, server \\ __MODULE__)
      when is_binary(id) and is_map(connection) do
    GenServer.call(server, {:confirm, id, connection}, 20_000)
  end

  @spec revert(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def revert(id, server \\ __MODULE__), do: GenServer.call(server, {:revert, id}, 30_000)

  @doc "Immediately applies and persists noncritical subnet-router settings."
  @spec configure_subnet_router(boolean(), [String.t()], GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def configure_subnet_router(enabled, routes, server \\ __MODULE__)
      when is_boolean(enabled) and is_list(routes) do
    GenServer.call(server, {:configure_subnet_router, enabled, routes}, 30_000)
  end

  @doc false
  @spec configure_ssh(boolean(), GenServer.server()) :: :ok | {:error, term()}
  def configure_ssh(enabled, server \\ __MODULE__) when is_boolean(enabled) do
    GenServer.call(server, {:configure_ssh, enabled}, 30_000)
  end

  @type heal_target :: :internet | :cluster | :ssh | :subnet_router

  @doc "Reapplies one runtime subsystem strictly from accepted settings."
  @spec heal(heal_target(), GenServer.server()) :: :ok | {:error, term()}
  def heal(target, server \\ __MODULE__)
      when target in [:internet, :cluster, :ssh, :subnet_router] do
    GenServer.call(server, {:heal, target}, 45_000)
  end

  @impl true
  def init(options) do
    if Keyword.has_key?(options, :initial_data) do
      init_public_server(options)
    else
      init_gateway_server(options)
    end
  end

  defp init_public_server(options) do
    if Keyword.get(options, :subscribe, false), do: subscribe_sources()

    {:ok,
     %__MODULE__{
       data: Keyword.fetch!(options, :initial_data),
       boot_id: Keyword.get_lazy(options, :boot_id, &new_boot_id/0)
     }}
  end

  defp init_gateway_server(options) do
    root = Keyword.get(options, :root, Storage.root())
    firmware = Keyword.get(options, :firmware, &firmware_metadata/0).()
    ops = Map.merge(Effects.default(), Map.new(Keyword.get(options, :ops, [])))

    case Persistence.hydrate(root, firmware) do
      {:ok, hydration} ->
        firmware = hydration.firmware
        current = hydration.current
        candidate = hydration.candidate
        DeviceStateAlarms.changing(false)
        subscribe_sources()

        state = %__MODULE__{
          root: root,
          firmware: firmware,
          current: current,
          ops: ops,
          boot_id: Keyword.get_lazy(options, :boot_id, &new_boot_id/0),
          keep_local_access:
            Keyword.get(
              options,
              :keep_local_access,
              Application.get_env(:nerves_gate, :local_dashboard, false)
            )
        }

        state = activate_current(state)
        state = if candidate, do: recover_candidate(state, candidate), else: state
        state = %{state | data: build_data(state.current)}
        configure_access(state)
        CommissioningAlarms.required(not state.current["configured"])
        {:ok, state}

      {:error, reason} ->
        StorageAlarms.failure(true)
        {:stop, {:device_state_unavailable, reason}}
    end
  end

  @impl true
  def handle_call(:data, _from, state), do: {:reply, state.data, state}
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_from(state), state}

  def handle_call(:observation, _from, state) do
    observation = snapshot_from(state) |> Map.put(:configuration, public_configuration(state))
    {:reply, observation, state}
  end

  def handle_call({:join, client}, _from, state) do
    state = monitor_client(state, client)
    {:reply, {:ok, snapshot_from(state)}, state}
  end

  def handle_call({:apply_operation, operation}, _from, state) do
    case apply_local_operation(state, operation) do
      {:ok, state} -> {:reply, :ok, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:configured?, _from, state) do
    {:reply, state.current["configured"], state}
  end

  def handle_call(:current, _from, state), do: {:reply, state.current, state}

  def handle_call(:configuration, _from, state) do
    {:reply, public_configuration(state), state}
  end

  def handle_call({:heal, _target}, _from, %{pending: pending} = state)
      when not is_nil(pending) do
    {:reply, {:error, :configuration_change_in_progress}, state}
  end

  def handle_call({:heal, target}, _from, state) do
    reply =
      if state.current["configured"],
        do: heal_runtime(target, state),
        else: {:error, :not_configured}

    {:reply, reply, state}
  end

  def handle_call(
        {:stage_internet, _params, _connection, _timeout},
        _from,
        %{pending: pending} = state
      )
      when not is_nil(pending) do
    {:reply, {:error, :configuration_change_in_progress}, state}
  end

  def handle_call({:stage_internet, params, source_connection, timeout}, _from, state) do
    id = change_id()
    timeout = if state.current["configured"], do: timeout, else: nil

    with {:ok, candidate} <- Settings.build_internet(state.current, params),
         :ok <- Persistence.write_candidate(candidate, state.root) do
      begin_change()

      case state.ops.internet.(internet(candidate)) do
        {:ok, _checks} ->
          {deadline, timer, timer_token} = start_timer(id, timeout)

          pending = %{
            id: id,
            phase: :tailnet,
            source_connection: source_connection,
            timeout: timeout,
            deadline: deadline,
            timer_token: timer_token,
            candidate: candidate
          }

          state = %{state | pending: pending, timer: timer, last_error: nil}
          publish(state)
          {:reply, {:ok, public_pending(pending)}, state}

        {:error, reason} ->
          state = rollback_candidate(state, candidate, reason)
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:update_internet, id, params},
        _from,
        %{pending: %{id: id} = pending} = state
      ) do
    case Settings.update_internet(pending.candidate, params) do
      {:ok, candidate} -> update_internet_runtime(state, pending, candidate)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update_internet, _id, _params}, _from, state) do
    {:reply, {:error, :configuration_change_not_found}, state}
  end

  def handle_call(
        {:stage_tailnet, id, params},
        _from,
        %{pending: %{id: id, phase: phase} = pending} = state
      )
      when phase in [:tailnet, :cluster, :confirmation] do
    auth_token = params |> Map.get("auth_token") |> blank_nil()

    with :ok <- Settings.validate_auth_token(auth_token, pending.candidate),
         {:ok, candidate} <- apply_tailnet(state, pending.candidate, auth_token, id) do
      persist_tailnet_candidate(state, pending, candidate)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stage_tailnet, _id, _params}, _from, state) do
    {:reply, {:error, :configuration_change_not_found}, state}
  end

  def handle_call(
        {:stage_cluster, id, params},
        _from,
        %{pending: %{id: id, phase: phase} = pending} = state
      )
      when phase in [:cluster, :confirmation] do
    group = params |> get_in(["cluster", "group"]) |> blank_nil()

    case ClusterManager.validate_group(group) do
      {:ok, group} ->
        candidate =
          pending.candidate
          |> Map.put("configured", true)
          |> Map.put("cluster", %{"group" => group})
          |> Settings.touch()

        update_cluster_runtime(state, pending, candidate, group)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stage_cluster, _id, _params}, _from, state) do
    {:reply, {:error, :configuration_change_not_found}, state}
  end

  def handle_call(
        {:configure_subnet_router, _enabled, _routes},
        _from,
        %{pending: pending} = state
      )
      when not is_nil(pending) do
    {:reply, {:error, :configuration_change_in_progress}, state}
  end

  def handle_call(
        {:configure_subnet_router, enabled, routes},
        _from,
        %{current: %{"configured" => true}} = state
      ) do
    routes = if enabled, do: routes, else: subnet_routes(state.current)

    with {:ok, requested} <-
           Settings.validate_subnet_router(%{"enabled" => enabled, "routes" => routes}),
         :ok <- Settings.require_enabled_routes(requested) do
      persist_subnet_router(state, requested)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:configure_subnet_router, _enabled, _routes}, _from, state) do
    {:reply, {:error, :gateway_not_configured}, state}
  end

  def handle_call({:configure_ssh, _enabled}, _from, %{pending: pending} = state)
      when not is_nil(pending) do
    {:reply, {:error, :configuration_change_in_progress}, state}
  end

  def handle_call(
        {:configure_ssh, enabled},
        _from,
        %{current: %{"configured" => true}} = state
      ) do
    persist_ssh(state, enabled)
  end

  def handle_call({:configure_ssh, _enabled}, _from, state) do
    {:reply, {:error, :gateway_not_configured}, state}
  end

  def handle_call(
        {:confirm, id, %{tailnet?: false}},
        _from,
        %{pending: %{id: id, phase: :confirmation}} = state
      ) do
    {:reply, {:error, :tailnet_connection_required}, state}
  end

  def handle_call(
        {:confirm, id, %{id: connection_id, tailnet?: true}},
        _from,
        %{pending: %{id: id, phase: :confirmation}} = state
      ) do
    if state.pending.source_connection == connection_id do
      {:reply, {:error, :fresh_connection_required}, state}
    else
      case Persistence.promote_candidate(state.firmware.active, state.root) do
        :ok ->
          cancel_timer(state)
          candidate = state.pending.candidate
          cleanup_result = cleanup_previous_tailnet(state.current, candidate, state.ops)
          subnet_result = restore_subnet_router(candidate, state.ops)
          accepted = state.current
          finish_change()
          CommissioningAlarms.required(false)

          state =
            %{
              state
              | current: candidate,
                pending: nil,
                timer: nil,
                last_error: post_confirmation_error(cleanup_result, subnet_result)
            }
            |> apply_name_change(accepted, candidate)

          configure_access(state)
          publish(state)
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, {:settings_promotion_failed, reason}}, state}
      end
    end
  end

  def handle_call({:confirm, id, _connection_id}, _from, %{pending: %{id: id}} = state) do
    {:reply, {:error, :configuration_incomplete}, state}
  end

  def handle_call({:confirm, _id, _connection_id}, _from, state) do
    {:reply, {:error, :configuration_change_not_found}, state}
  end

  def handle_call({:revert, id}, _from, %{pending: %{id: id}} = state) do
    {reply, state} = revert_pending(state, :reverted)
    {:reply, reply, state}
  end

  def handle_call({:revert, _id}, _from, state) do
    {:reply, {:error, :configuration_change_not_found}, state}
  end

  @impl true
  def handle_info(%Alarmist.Event{} = event, state) do
    operation =
      case Alarms.public_event(event) do
        {:set, alarm} -> {:set_alarm, :alarms, alarm}
        {:clear, id} -> {:clear_alarm, :alarms, id}
        :ignore -> nil
      end

    {:noreply, maybe_apply_local_operation(state, operation)}
  end

  def handle_info({:internet_changed, status}, state) do
    operation = {:set_internet, :internet, internet_data(status)}
    {:noreply, apply_valid_local_operation(state, operation)}
  end

  def handle_info({:cluster_changed, status}, state) do
    operation = {:set_cluster, :cluster, cluster_data(status)}
    {:noreply, apply_valid_local_operation(state, operation)}
  end

  def handle_info({:ssh_changed, status}, state) do
    operation = {:observe_ssh, :ssh, status}
    {:noreply, apply_valid_local_operation(state, operation)}
  end

  def handle_info({:DOWN, reference, :process, client, _reason}, state) do
    case Map.get(state.clients, client) do
      ^reference -> {:noreply, %{state | clients: Map.delete(state.clients, client)}}
      _other -> {:noreply, state}
    end
  end

  def handle_info(
        {:revert_timeout, id, timer_token},
        %{pending: %{id: id, timer_token: timer_token}} = state
      )
      when not is_nil(timer_token) do
    {_reply, state} = revert_pending(state, :revert_timeout)
    {:noreply, state}
  end

  def handle_info({:revert_timeout, _id, _timer_token}, state), do: {:noreply, state}

  def handle_info({:tailnet_changed, status}, state) do
    state =
      state
      |> apply_valid_local_operation({:set_tailnet, :tailnet, tailnet_data(status)})
      |> apply_valid_local_operation(
        {:observe_subnet_router, :subnet_router, subnet_router_observation(status)}
      )

    {:noreply, state}
  end

  defp maybe_apply_local_operation(state, nil), do: state

  defp maybe_apply_local_operation(state, operation),
    do: apply_valid_local_operation(state, operation)

  defp apply_valid_local_operation(state, operation) do
    {:ok, state} = apply_local_operation(state, operation)
    state
  end

  defp apply_local_operation(state, operation) do
    case Data.apply_operation(state.data, operation) do
      {:ok, data, actions} when data == state.data ->
        {:ok, execute_actions(actions, state, false)}

      {:ok, data, actions} ->
        revision = state.revision + 1
        message = {:device_state_operation, node(), state.boot_id, revision, operation}
        Enum.each(Map.keys(state.clients), &send(&1, message))
        state = %{state | data: data, revision: revision}
        {:ok, execute_actions(actions, state, true)}

      :error ->
        :error
    end
  end

  defp execute_actions(actions, state, data_changed?) do
    Enum.reduce(actions, state, fn
      :broadcast, state when data_changed? ->
        Phoenix.PubSub.local_broadcast(
          NervesGate.PubSub,
          "device_state",
          {:local_state_changed, state.data}
        )

        state

      :broadcast, state ->
        state

      {:apply_subnet_router, enabled, routes}, state ->
        requested = %{"enabled" => enabled, "routes" => routes}

        state =
          case apply_subnet_router(requested, state.ops) do
            {:ok, _applied_routes} ->
              %{state | last_error: nil}

            {:error, reason} ->
              state
              |> subnet_router_error(reason)
              |> apply_valid_local_operation({:fail_subnet_router, :subnet_router, :apply_failed})
          end

        state

      {:configure_ssh, enabled}, state ->
        :ok = state.ops.ssh.(enabled)
        state
    end)
  end

  defp monitor_client(state, client) do
    case Map.fetch(state.clients, client) do
      {:ok, _reference} -> state
      :error -> %{state | clients: Map.put(state.clients, client, Process.monitor(client))}
    end
  end

  defp snapshot_from(state) do
    %{boot_id: state.boot_id, revision: state.revision, data: state.data}
  end

  defp build_data(settings) do
    identity = Identity.get()
    tailnet = Observer.status()

    Data.new(
      device_id: identity.machine_id,
      name: Map.get(settings, "name", identity.hostname),
      firmware_version: application_version(),
      internet: internet_data(Monitor.status()),
      tailnet: tailnet_data(tailnet),
      subnet_router: subnet_router_data(settings, tailnet),
      ssh: SSH.status(),
      cluster: cluster_data(ClusterManager.status()),
      alarms: Alarms.active()
    )
  end

  defp internet_data(status) do
    %{
      status: if(Map.get(status, :online, false), do: :online, else: :failed),
      reason: Map.get(status, :reason)
    }
  end

  defp tailnet_data(status) do
    observed_status = if Map.get(status, :online, false), do: :online, else: :offline

    %{
      observed_status: observed_status,
      authenticated: Map.get(status, :authenticated, :unknown),
      hostname: Map.get(status, :hostname),
      ipv4: Map.get(status, :ipv4)
    }
  end

  defp subnet_router_data(settings, tailnet_status) do
    desired = subnet_router(settings)

    Map.merge(
      %{enabled: desired["enabled"], routes: desired["routes"]},
      subnet_router_observation(tailnet_status)
    )
  end

  defp subnet_router_observation(tailnet_status) do
    observed = Map.get(tailnet_status, :subnet_router, unavailable_subnet_router())

    %{
      advertised: Map.get(observed, :advertised, []),
      approved: Map.get(observed, :approved, []),
      primary: Map.get(observed, :primary, []),
      error: Map.get(observed, :error)
    }
  end

  defp cluster_data(status) do
    enabled = Map.get(status, :enabled, false)
    online = Map.get(status, :online, false)

    %{
      runtime_status: cluster_runtime_status(enabled, online),
      enabled: enabled,
      group: Map.get(status, :group),
      node: encode_node(Map.get(status, :node)),
      connected: status |> Map.get(:connected, []) |> Enum.map(&to_string/1) |> Enum.sort()
    }
  end

  defp cluster_runtime_status(false, _online), do: :disabled
  defp cluster_runtime_status(true, true), do: :online
  defp cluster_runtime_status(true, false), do: :failed

  defp encode_node(nil), do: nil
  defp encode_node(node), do: to_string(node)

  defp application_version, do: Application.spec(:nerves_gate, :vsn) |> to_string()

  defp new_boot_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp subscribe_sources do
    Enum.each(~w(internet tailnet ssh cluster), fn topic ->
      Phoenix.PubSub.subscribe(NervesGate.PubSub, topic)
    end)

    Alarms.subscribe_public()
  end

  defp heal_runtime(:internet, state) do
    with :ok <- heal_effect(state.ops.internet_restore.(internet(state.current))) do
      heal_effect(state.ops.internet_observe.())
    end
  end

  defp heal_runtime(:cluster, state) do
    state.ops.cluster.(cluster_group(state.current)) |> heal_effect()
  end

  defp heal_runtime(:ssh, state) do
    state.ops.ssh.(ssh_enabled(state.current)) |> heal_effect()
  end

  defp heal_runtime(:subnet_router, state) do
    case apply_subnet_router(subnet_router(state.current), state.ops) do
      {:ok, _routes} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp heal_effect(:ok), do: :ok
  defp heal_effect({:ok, _value}), do: :ok
  defp heal_effect({:error, _reason} = error), do: error
  defp heal_effect(invalid), do: {:error, {:invalid_heal_result, invalid}}

  defp unavailable_subnet_router do
    %{advertised: [], approved: [], primary: [], error: :unavailable}
  end

  defp subnet_router_error(state, reason),
    do: %{state | last_error: {:subnet_router_activation_failed, reason}}

  defp update_internet_runtime(state, pending, candidate) do
    case state.ops.internet.(internet(candidate)) do
      {:ok, _checks} -> persist_internet_candidate(state, pending, candidate)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp persist_internet_candidate(state, pending, candidate) do
    case Persistence.write_candidate(candidate, state.root) do
      :ok ->
        state = advance_change(state, pending, pending.phase, candidate)
        publish(state)
        {:reply, {:ok, public_pending(state.pending)}, state}

      {:error, reason} ->
        state.ops.internet_restore.(internet(pending.candidate))
        {:reply, {:error, {:candidate_write_failed, reason}}, state}
    end
  end

  defp persist_tailnet_candidate(state, pending, candidate) do
    case Persistence.write_candidate(candidate, state.root) do
      :ok ->
        cleanup_result = cleanup_replaced_tailnet(state, pending.candidate, candidate)
        next_phase = if pending.phase == :tailnet, do: :cluster, else: pending.phase

        state =
          state
          |> advance_change(pending, next_phase, candidate)
          |> Map.put(:last_error, cleanup_error(cleanup_result))

        publish(state)
        {:reply, {:ok, public_pending(state.pending)}, state}

      {:error, reason} ->
        rollback_new_tailnet(pending.candidate, candidate, state.ops)
        {:reply, {:error, {:candidate_write_failed, reason}}, state}
    end
  end

  defp persist_subnet_router(state, requested) do
    updated = Settings.bump(state.current, %{"subnet_router" => requested})

    case Persistence.write_slot(updated, state.firmware.active, state.root) do
      :ok ->
        state =
          %{state | current: updated, last_error: nil}
          |> apply_valid_local_operation(
            {:configure_subnet_router, :subnet_router,
             %{enabled: requested["enabled"], routes: requested["routes"]}}
          )

        publish(state)

        case state.last_error do
          {:subnet_router_activation_failed, reason} ->
            {:reply, {:error, {:subnet_router_apply_failed, reason}}, state}

          _no_error ->
            {:reply, {:ok, Settings.public(updated).subnet_router}, state}
        end

      {:error, reason} ->
        {:reply, {:error, {:settings_write_failed, reason}}, state}
    end
  end

  defp persist_ssh(state, enabled) do
    updated = Settings.bump(state.current, %{"ssh_enabled" => enabled})

    case Persistence.write_slot(updated, state.firmware.active, state.root) do
      :ok ->
        state =
          %{state | current: updated, last_error: nil}
          |> apply_valid_local_operation({:configure_ssh, :ssh, %{enabled: enabled}})

        publish(state)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, {:settings_write_failed, reason}}, state}
    end
  end

  defp update_cluster_runtime(state, pending, candidate, group) do
    case state.ops.cluster.(group) do
      :ok -> persist_cluster_candidate(state, pending, candidate)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp persist_cluster_candidate(state, pending, candidate) do
    case Persistence.write_candidate(candidate, state.root) do
      :ok ->
        state = advance_change(state, pending, :confirmation, candidate)
        publish(state)
        {:reply, {:ok, public_pending(state.pending)}, state}

      {:error, reason} ->
        state.ops.cluster.(cluster_group(pending.candidate))
        {:reply, {:error, {:candidate_write_failed, reason}}, state}
    end
  end

  defp apply_tailnet(_state, candidate, nil, _id) do
    case tailnet_profile(candidate) do
      profile_id when is_binary(profile_id) -> {:ok, candidate}
      nil -> {:error, :tailscale_auth_key_required}
    end
  end

  defp apply_tailnet(state, candidate, auth_token, id) do
    previous_profile_id = tailnet_profile(candidate)

    case state.ops.stage_tailnet.(auth_token, id, previous_profile_id) do
      {:ok, %{"candidate_profile_id" => candidate_profile_id}}
      when is_binary(candidate_profile_id) ->
        candidate = put_in(candidate, ["tailnet", "profile_id"], candidate_profile_id)
        {:ok, Settings.touch(candidate)}

      {:error, reason, metadata} ->
        state.ops.rollback_tailnet.(metadata)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, :tailnet_candidate_unavailable}
    end
  end

  defp revert_pending(state, reason) do
    cancel_timer(state)
    candidate = state.pending.candidate
    state = rollback_candidate(state, candidate, reason)

    reply =
      if match?({:rollback_failed, _}, state.last_error),
        do: {:error, state.last_error},
        else: :ok

    {reply, state}
  end

  defp rollback_candidate(state, candidate, reason) do
    rollback_result = restore_runtime(state.current, candidate, state.ops)
    clear_result = Persistence.clear_candidate(state.root)
    finish_change()

    last_error =
      case {rollback_result, clear_result} do
        {:ok, :ok} -> reason
        {{:error, failures}, _clear} -> {:rollback_failed, failures}
        {:ok, {:error, clear_reason}} -> {:candidate_cleanup_failed, clear_reason}
      end

    state = %{state | pending: nil, timer: nil, last_error: last_error}
    configure_access(state)
    publish(state)
    state
  end

  defp restore_runtime(current, candidate, ops) do
    results = [
      internet: ops.internet_restore.(internet(current)),
      tailnet: ops.rollback_tailnet.(tailnet_metadata(current, candidate)),
      subnet_router: restore_subnet_router(current, ops),
      ssh: ops.ssh.(ssh_enabled(current)),
      cluster: ops.cluster.(cluster_group(current))
    ]

    failures = Enum.reject(results, fn {_layer, result} -> result in [:ok, {:ok, nil}] end)
    if failures == [], do: :ok, else: {:error, failures}
  end

  defp recover_candidate(state, candidate) do
    result = restore_runtime(state.current, candidate, state.ops)
    clear_result = Persistence.clear_candidate(state.root)

    last_error =
      case {result, clear_result} do
        {:ok, :ok} -> :recovered_unconfirmed_configuration
        {{:error, failures}, _clear} -> {:rollback_failed, failures}
        {:ok, {:error, reason}} -> {:candidate_cleanup_failed, reason}
      end

    %{state | last_error: last_error}
  end

  defp activate_current(state) do
    results = [
      internet: state.ops.internet_restore.(internet(state.current)),
      tailnet: state.ops.tailnet_restore.(tailnet_profile(state.current)),
      subnet_router: restore_subnet_router(state.current, state.ops),
      ssh: state.ops.ssh.(ssh_enabled(state.current)),
      cluster: state.ops.cluster.(cluster_group(state.current))
    ]

    failures = Enum.reject(results, fn {_layer, result} -> result == :ok end)
    if failures == [], do: state, else: %{state | last_error: {:activation_failed, failures}}
  end

  defp cleanup_previous_tailnet(current, candidate, ops) do
    ops.commit_tailnet.(tailnet_metadata(current, candidate))
  end

  defp cleanup_replaced_tailnet(state, previous_candidate, candidate) do
    if tailnet_profile(previous_candidate) == tailnet_profile(state.current) do
      :ok
    else
      state.ops.commit_tailnet.(tailnet_metadata(previous_candidate, candidate))
    end
  end

  defp rollback_new_tailnet(previous_candidate, candidate, ops) do
    ops.rollback_tailnet.(tailnet_metadata(previous_candidate, candidate))
  end

  defp cleanup_error(:ok), do: nil
  defp cleanup_error({:error, reason}), do: {:tailnet_profile_cleanup_failed, reason}

  defp post_confirmation_error(cleanup_result, subnet_result) do
    cleanup_error(cleanup_result) ||
      runtime_error(:subnet_router_activation_failed, subnet_result)
  end

  defp runtime_error(_type, :ok), do: nil
  defp runtime_error(type, {:error, reason}), do: {type, reason}

  defp restore_subnet_router(%{"configured" => false}, _ops) do
    SubnetRouterAlarms.failure(false)
    :ok
  end

  defp restore_subnet_router(settings, ops) do
    case apply_subnet_router(subnet_router(settings), ops) do
      {:ok, _routes} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp apply_subnet_router(%{"enabled" => enabled, "routes" => routes}, ops) do
    case ops.subnet_router.(enabled, routes) do
      {:ok, applied_routes} when is_list(applied_routes) ->
        SubnetRouterAlarms.failure(false)
        {:ok, applied_routes}

      {:error, _reason} = error ->
        SubnetRouterAlarms.failure(true)
        error

      invalid ->
        SubnetRouterAlarms.failure(true)
        {:error, {:invalid_subnet_router_result, invalid}}
    end
  end

  defp tailnet_metadata(current, candidate) do
    %{
      "previous_profile_id" => tailnet_profile(current),
      "candidate_profile_id" => tailnet_profile(candidate)
    }
  end

  defp public_configuration(state) do
    %{
      configured: state.current["configured"],
      current: Settings.public(state.current),
      pending: if(state.pending, do: public_pending(state.pending)),
      last_error: state.last_error
    }
  end

  defp public_pending(pending) do
    %{
      id: pending.id,
      phase: pending.phase,
      candidate: Settings.public(pending.candidate),
      remaining_seconds: remaining_seconds(pending.deadline)
    }
  end

  defp remaining_seconds(nil), do: nil

  defp remaining_seconds(deadline) do
    max(0, div(deadline - System.monotonic_time(:millisecond) + 999, 1_000))
  end

  defp configure_access(state) do
    cond do
      not state.current["configured"] ->
        state.ops.access.(:commissioning, active_interface(state.current))

      state.keep_local_access ->
        state.ops.access.(:commissioning, active_interface(state.current))

      true ->
        state.ops.disable_access.()
    end
  end

  defp active_interface(settings) do
    case internet(settings) do
      %Config{interface: interface} -> interface
      nil -> nil
    end
  end

  defp begin_change, do: DeviceStateAlarms.changing(true)
  defp finish_change, do: DeviceStateAlarms.changing(false)

  defp apply_name_change(state, %{"name" => name}, %{"name" => name}), do: state

  defp apply_name_change(state, _accepted, %{"name" => name}) do
    apply_valid_local_operation(state, {:set_name, :device, name})
  end

  defp publish(state) do
    Phoenix.PubSub.local_broadcast(
      NervesGate.PubSub,
      "configuration",
      {:configuration_changed, public_configuration(state)}
    )
  end

  defp advance_change(state, pending, phase, candidate) do
    cancel_timer(state)
    {deadline, timer, timer_token} = start_timer(pending.id, pending.timeout)

    pending = %{
      pending
      | phase: phase,
        deadline: deadline,
        timer_token: timer_token,
        candidate: candidate
    }

    %{state | pending: pending, timer: timer, last_error: nil}
  end

  defp start_timer(_id, nil), do: {nil, nil, nil}

  defp start_timer(id, timeout) do
    timer_token = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout
    timer = Process.send_after(self(), {:revert_timeout, id, timer_token}, timeout)
    {deadline, timer, timer_token}
  end

  defp cancel_timer(%{timer: nil}), do: :ok
  defp cancel_timer(state), do: Process.cancel_timer(state.timer)

  defp firmware_metadata do
    %{active: active} = Nerves.Runtime.firmware_slots()

    slots =
      Map.new(@slots, fn slot ->
        {slot,
         %{
           "uuid" => Nerves.Runtime.KV.get("#{slot}.nerves_fw_uuid") || "unknown",
           "version" => Nerves.Runtime.KV.get("#{slot}.nerves_fw_version") || "unknown"
         }}
      end)

    %{active: active, slots: slots}
  end

  defp internet(settings), do: Settings.internet(settings)
  defp tailnet_profile(settings), do: Settings.tailnet_profile(settings)
  defp subnet_router(settings), do: Settings.subnet_router(settings)
  defp subnet_routes(settings), do: Settings.subnet_routes(settings)
  defp ssh_enabled(settings), do: Settings.ssh_enabled(settings)
  defp cluster_group(settings), do: Settings.cluster_group(settings)

  defp blank_nil(nil), do: nil
  defp blank_nil(value) when is_binary(value), do: value |> String.trim() |> empty_nil()
  defp empty_nil(""), do: nil
  defp empty_nil(value), do: value

  defp change_id do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end

defimpl Inspect, for: NervesGate.DeviceState.Server do
  import Inspect.Algebra

  def inspect(state, opts) do
    settings = state.current || %{}

    public = %{
      firmware: state.firmware,
      configured: settings["configured"],
      revision: settings["revision"],
      pending: not is_nil(state.pending),
      last_error: state.last_error
    }

    concat(["#NervesGate.DeviceState.Server<", to_doc(public, opts), ">"])
  end
end
