defmodule NervesGate.Configuration.Signal.Changing do
  @moduledoc "Raw condition indicating that a complete settings candidate is active."
  def description, do: "Configuration change in progress"
end

defmodule NervesGate.Configuration do
  @moduledoc """
  Owns the complete gateway configuration as firmware-tagged A/B snapshots.

  The running firmware reads `settings-a.json` or `settings-b.json`. A change is
  written to `settings-candidate.json`, applied temporarily, and promoted over
  the running slot only after confirmation from a fresh connection. A timeout
  or process/device restart discards the candidate and restores the slot file.
  """

  use GenServer

  alias NervesGate.Alarms
  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.Commissioning.Access
  alias NervesGate.Commissioning.Alarms, as: CommissioningAlarms
  alias NervesGate.Identity
  alias NervesGate.Internet.Config
  alias NervesGate.Internet.Manager, as: InternetManager
  alias NervesGate.Storage.Alarms, as: StorageAlarms
  alias NervesGate.Store
  alias NervesGate.Tailnet.Observer
  alias NervesGate.Tailscale

  @slots ["a", "b"]
  @default_timeout :timer.minutes(1)

  defstruct [
    :root,
    :firmware,
    :current,
    :pending,
    :timer,
    :ops,
    :last_error,
    keep_local_access: false
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec configured?(GenServer.server()) :: boolean()
  def configured?(server \\ __MODULE__), do: GenServer.call(server, :configured?)

  @spec current(GenServer.server()) :: map()
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @spec status(String.t() | nil, GenServer.server()) :: map()
  def status(connection_id \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:status, connection_id})
  end

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

  @spec confirm(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def confirm(id, connection_id, server \\ __MODULE__) do
    GenServer.call(server, {:confirm, id, connection_id}, 20_000)
  end

  @spec revert(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def revert(id, server \\ __MODULE__), do: GenServer.call(server, {:revert, id}, 30_000)

  @spec changing?() :: boolean()
  def changing? do
    Alarmist.alarm_state(NervesGate.Configuration.Signal.Changing) == :set
  end

  @doc false
  @spec validate_settings(map()) :: {:ok, map()} | {:error, term()}
  def validate_settings(
        %{
          "version" => 1,
          "firmware" => %{
            "slot" => slot,
            "uuid" => uuid,
            "version" => firmware_version
          },
          "revision" => revision,
          "configured" => configured,
          "internet" => persisted_internet,
          "tailnet" => %{"profile_id" => profile_id},
          "cluster" => %{"group" => group},
          "name" => name
        } = settings
      )
      when slot in @slots and is_binary(uuid) and is_binary(firmware_version) and
             is_integer(revision) and revision >= 0 and is_boolean(configured) and
             (is_binary(profile_id) or is_nil(profile_id)) do
    with :ok <- validate_profile_id(profile_id, configured),
         :ok <- validate_updated_at(Map.get(settings, "updated_at")),
         {:ok, internet} <- validate_internet(persisted_internet, configured),
         {:ok, group} <- ClusterManager.validate_group(group),
         {:ok, name} <- valid_name(name) do
      {:ok,
       settings
       |> Map.take([
         "version",
         "firmware",
         "revision",
         "configured",
         "updated_at",
         "internet",
         "tailnet",
         "cluster",
         "name"
       ])
       |> Map.put("internet", if(internet, do: Config.to_persisted(internet)))
       |> Map.put("tailnet", %{"profile_id" => profile_id})
       |> Map.put("cluster", %{"group" => group})
       |> Map.put("name", name)
       |> Map.put_new("updated_at", nil)}
    end
  end

  def validate_settings(_settings), do: {:error, :invalid_settings}

  @impl true
  def init(options) do
    root = Keyword.get(options, :root, Store.root())
    firmware = Keyword.get(options, :firmware, &firmware_metadata/0).()
    ops = Map.merge(default_ops(), Map.new(Keyword.get(options, :ops, [])))

    with :ok <- Store.initialize(root),
         :ok <- Store.clear_legacy_settings(root),
         {:ok, firmware} <- normalize_firmware(firmware),
         :ok <- ensure_slot_files(root, firmware),
         {:ok, current} <- load_current(root, firmware),
         {:ok, candidate} <- read_candidate_or_nil(root) do
      Alarms.clear(NervesGate.Configuration.Signal.Changing)
      Phoenix.PubSub.subscribe(NervesGate.PubSub, "tailnet")

      state = %__MODULE__{
        root: root,
        firmware: firmware,
        current: current,
        ops: ops,
        keep_local_access:
          Keyword.get(
            options,
            :keep_local_access,
            Application.get_env(:nerves_gate, :local_dashboard, false)
          )
      }

      state = activate_current(state)
      state = if candidate, do: recover_candidate(state, candidate), else: state
      configure_access(state)
      CommissioningAlarms.required(not state.current["configured"])
      {:ok, state}
    else
      {:error, reason} ->
        StorageAlarms.failure(true)
        {:stop, {:configuration_unavailable, reason}}
    end
  end

  @impl true
  def handle_call(:configured?, _from, state) do
    {:reply, state.current["configured"], state}
  end

  def handle_call(:current, _from, state), do: {:reply, state.current, state}

  def handle_call({:status, connection_id}, _from, state) do
    {:reply, public_status(state, connection_id), state}
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

    with {:ok, candidate} <- build_internet_candidate(state, params),
         :ok <- write_candidate(candidate, state.root) do
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
          {:reply, {:ok, public_pending(pending, source_connection)}, state}

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
    case update_internet_candidate(pending.candidate, params) do
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

    with :ok <- validate_auth_token(auth_token, pending.candidate),
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
          |> touch()

        update_cluster_runtime(state, pending, candidate, group)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stage_cluster, _id, _params}, _from, state) do
    {:reply, {:error, :configuration_change_not_found}, state}
  end

  def handle_call(
        {:confirm, id, connection_id},
        _from,
        %{pending: %{id: id, phase: :confirmation}} = state
      ) do
    if state.pending.source_connection == connection_id do
      {:reply, {:error, :fresh_connection_required}, state}
    else
      case Store.promote_candidate(state.firmware.active, state.root) do
        :ok ->
          cancel_timer(state)
          candidate = state.pending.candidate
          cleanup_result = cleanup_previous_tailnet(state.current, candidate, state.ops)
          publish_name_change(state.current, candidate)
          finish_change()
          CommissioningAlarms.required(false)

          state = %{
            state
            | current: candidate,
              pending: nil,
              timer: nil,
              last_error: cleanup_error(cleanup_result)
          }

          configure_access(state)
          publish(state)
          {:reply, :ok, state}

        {:error, reason} ->
          StorageAlarms.failure(true)
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
  def handle_info(
        {:revert_timeout, id, timer_token},
        %{pending: %{id: id, timer_token: timer_token}} = state
      )
      when not is_nil(timer_token) do
    {_reply, state} = revert_pending(state, :revert_timeout)
    {:noreply, state}
  end

  def handle_info({:revert_timeout, _id, _timer_token}, state), do: {:noreply, state}

  def handle_info({:tailnet_changed, _status}, %{pending: nil} = state) do
    case state.ops.tailnet_restore.(tailnet_profile(state.current)) do
      :ok -> {:noreply, clear_tailnet_activation_error(state)}
      {:error, reason} -> {:noreply, %{state | last_error: {:tailnet_activation_failed, reason}}}
    end
  end

  def handle_info({:tailnet_changed, _status}, state), do: {:noreply, state}

  defp clear_tailnet_activation_error(
         %{last_error: {:tailnet_activation_failed, _reason}} = state
       ),
       do: %{state | last_error: nil}

  defp clear_tailnet_activation_error(%{last_error: {:activation_failed, failures}} = state) do
    case Keyword.delete(failures, :tailnet) do
      [] -> %{state | last_error: nil}
      remaining -> %{state | last_error: {:activation_failed, remaining}}
    end
  end

  defp clear_tailnet_activation_error(state), do: state

  defp update_internet_runtime(state, pending, candidate) do
    case state.ops.internet.(internet(candidate)) do
      {:ok, _checks} -> persist_internet_candidate(state, pending, candidate)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp persist_internet_candidate(state, pending, candidate) do
    case write_candidate(candidate, state.root) do
      :ok ->
        state = advance_change(state, pending, pending.phase, candidate)
        publish(state)
        {:reply, {:ok, public_pending(state.pending, pending.source_connection)}, state}

      {:error, reason} ->
        state.ops.internet_restore.(internet(pending.candidate))
        {:reply, {:error, {:candidate_write_failed, reason}}, state}
    end
  end

  defp persist_tailnet_candidate(state, pending, candidate) do
    case write_candidate(candidate, state.root) do
      :ok ->
        cleanup_result = cleanup_replaced_tailnet(state, pending.candidate, candidate)
        state.ops.poll_tailnet.()
        next_phase = if pending.phase == :tailnet, do: :cluster, else: pending.phase

        state =
          state
          |> advance_change(pending, next_phase, candidate)
          |> Map.put(:last_error, cleanup_error(cleanup_result))

        publish(state)
        {:reply, {:ok, public_pending(state.pending, pending.source_connection)}, state}

      {:error, reason} ->
        rollback_new_tailnet(pending.candidate, candidate, state.ops)
        {:reply, {:error, {:candidate_write_failed, reason}}, state}
    end
  end

  defp update_cluster_runtime(state, pending, candidate, group) do
    case state.ops.cluster.(group) do
      :ok -> persist_cluster_candidate(state, pending, candidate)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp persist_cluster_candidate(state, pending, candidate) do
    case write_candidate(candidate, state.root) do
      :ok ->
        state = advance_change(state, pending, :confirmation, candidate)
        publish(state)
        {:reply, {:ok, public_pending(state.pending, pending.source_connection)}, state}

      {:error, reason} ->
        state.ops.cluster.(cluster_group(pending.candidate))
        {:reply, {:error, {:candidate_write_failed, reason}}, state}
    end
  end

  defp build_internet_candidate(state, params) do
    internet_params = Map.get(params, "internet", %{})
    name = params |> get_in(["device", "name"]) || state.current["name"]

    with {:ok, internet} <- Config.new(normalize_internet(internet_params)),
         {:ok, name} <- valid_name(name) do
      candidate =
        bump(state.current, %{
          "internet" => Config.to_persisted(internet),
          "name" => name
        })

      {:ok, candidate}
    end
  end

  defp update_internet_candidate(candidate, params) do
    internet_params = Map.get(params, "internet", %{})
    name = params |> get_in(["device", "name"]) || candidate["name"]

    with {:ok, internet} <- Config.new(normalize_internet(internet_params)),
         {:ok, name} <- valid_name(name) do
      {:ok,
       candidate
       |> Map.put("internet", Config.to_persisted(internet))
       |> Map.put("name", name)
       |> touch()}
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
        {:ok, touch(candidate)}

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
    clear_result = Store.clear_candidate(state.root) |> storage_result()
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
      cluster: ops.cluster.(cluster_group(current))
    ]

    failures = Enum.reject(results, fn {_layer, result} -> result in [:ok, {:ok, nil}] end)
    if failures == [], do: :ok, else: {:error, failures}
  end

  defp recover_candidate(state, candidate) do
    result = restore_runtime(state.current, candidate, state.ops)
    clear_result = Store.clear_candidate(state.root) |> storage_result()

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

  defp tailnet_metadata(current, candidate) do
    %{
      "previous_profile_id" => tailnet_profile(current),
      "candidate_profile_id" => tailnet_profile(candidate)
    }
  end

  defp public_status(state, connection_id) do
    %{
      configured: state.current["configured"],
      current: public_settings(state.current),
      pending: if(state.pending, do: public_pending(state.pending, connection_id)),
      last_error: state.last_error
    }
  end

  defp public_settings(settings) do
    %{
      firmware: settings["firmware"],
      revision: settings["revision"],
      configured: settings["configured"],
      updated_at: settings["updated_at"],
      internet: Config.to_public(internet(settings)),
      tailnet_configured: is_binary(tailnet_profile(settings)),
      cluster_group: cluster_group(settings),
      name: settings["name"]
    }
  end

  defp public_pending(pending, connection_id) do
    %{
      id: pending.id,
      phase: pending.phase,
      candidate: public_settings(pending.candidate),
      remaining_seconds: remaining_seconds(pending.deadline),
      confirmable:
        pending.phase == :confirmation and is_binary(connection_id) and
          pending.source_connection != connection_id
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

  defp begin_change do
    Alarms.set(
      NervesGate.Configuration.Signal.Changing,
      NervesGate.Configuration.Signal.Changing.description()
    )
  end

  defp finish_change, do: Alarms.clear(NervesGate.Configuration.Signal.Changing)

  defp publish_name_change(%{"name" => name}, %{"name" => name}), do: :ok

  defp publish_name_change(_current, %{"name" => name}) do
    Phoenix.PubSub.local_broadcast(
      NervesGate.PubSub,
      "device",
      {:device_changed, %{"name" => name}}
    )
  end

  defp publish(state) do
    Phoenix.PubSub.local_broadcast(
      NervesGate.PubSub,
      "configuration",
      {:configuration_changed, public_status(state, nil)}
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

  defp ensure_slot_files(root, firmware) do
    Enum.reduce_while(@slots, :ok, &ensure_slot(&1, &2, root, firmware))
  end

  defp ensure_slot(slot, :ok, root, firmware) do
    case read_slot(slot, root) do
      {:ok, nil} ->
        continue_or_halt(write_slot(default_settings(firmware.slots[slot]), slot, root))

      {:ok, _settings} ->
        {:cont, :ok}

      {:error, _reason} ->
        StorageAlarms.failure(true)
        continue_or_halt(write_slot(default_settings(firmware.slots[slot]), slot, root))
    end
  end

  defp continue_or_halt(:ok), do: {:cont, :ok}
  defp continue_or_halt({:error, reason}), do: {:halt, {:error, reason}}

  defp load_current(root, firmware) do
    slot = firmware.active
    other_slot = opposite(slot)

    with {:ok, current} when not is_nil(current) <- read_slot(slot, root),
         {:ok, other} when not is_nil(other) <- read_slot(other_slot, root) do
      current_tagged? = current["firmware"] == firmware.slots[slot]

      cond do
        current_tagged? and current["configured"] -> {:ok, current}
        other["configured"] -> migrate_current(root, firmware, other)
        current_tagged? -> {:ok, current}
        true -> migrate_current(root, firmware, current)
      end
    end
  end

  defp migrate_current(root, firmware, source) do
    migrated = Map.put(source, "firmware", firmware.slots[firmware.active])

    with :ok <- write_slot(migrated, firmware.active, root) do
      {:ok, migrated}
    end
  end

  defp read_slot(slot, root) do
    Store.read_json(Store.settings_path(slot, root), &validate_settings/1, nil)
  end

  defp read_candidate_or_nil(root) do
    case Store.read_json(Store.candidate_path(root), &validate_settings/1, nil) do
      {:ok, candidate} ->
        {:ok, candidate}

      {:error, _reason} ->
        StorageAlarms.failure(true)
        {:ok, nil}
    end
  end

  defp write_slot(settings, slot, root) do
    with {:ok, settings} <- validate_settings(settings) do
      Store.write_json(Store.settings_path(slot, root), settings) |> storage_result()
    end
  end

  defp write_candidate(settings, root) do
    with {:ok, settings} <- validate_settings(settings) do
      Store.write_json(Store.candidate_path(root), settings) |> storage_result()
    end
  end

  defp storage_result(:ok), do: :ok

  defp storage_result({:error, _reason} = error) do
    StorageAlarms.failure(true)
    error
  end

  defp normalize_firmware(%{active: active, slots: slots}) when active in @slots do
    normalized = Map.new(@slots, fn slot -> {slot, normalize_tag(slot, slots[slot])} end)
    {:ok, %{active: active, slots: normalized}}
  end

  defp normalize_firmware(_firmware), do: {:error, :invalid_firmware_metadata}

  defp normalize_tag(slot, tag) do
    tag = Map.new(tag || %{}, fn {key, value} -> {to_string(key), value} end)

    %{
      "slot" => slot,
      "uuid" => to_string(tag["uuid"] || "unknown"),
      "version" => to_string(tag["version"] || "unknown")
    }
  end

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

  defp default_settings(firmware) do
    %{
      "version" => 1,
      "firmware" => firmware,
      "revision" => 0,
      "configured" => false,
      "updated_at" => nil,
      "internet" => nil,
      "tailnet" => %{"profile_id" => nil},
      "cluster" => %{"group" => nil},
      "name" => Identity.get().hostname
    }
  end

  defp validate_profile_id(nil, false), do: :ok
  defp validate_profile_id(nil, true), do: {:error, :tailnet_profile_required}

  defp validate_profile_id(profile_id, _configured)
       when is_binary(profile_id) and byte_size(profile_id) in 1..512,
       do: :ok

  defp validate_profile_id(_profile_id, _configured),
    do: {:error, :invalid_tailnet_profile}

  defp validate_updated_at(nil), do: :ok

  defp validate_updated_at(updated_at) when is_binary(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, _datetime, _offset} -> :ok
      {:error, _reason} -> {:error, :invalid_updated_at}
    end
  end

  defp validate_updated_at(_updated_at), do: {:error, :invalid_updated_at}

  defp validate_internet(nil, false), do: {:ok, nil}
  defp validate_internet(nil, true), do: {:error, :internet_configuration_required}
  defp validate_internet(settings, _configured), do: Config.from_persisted(settings)

  defp internet(%{"internet" => nil}), do: nil

  defp internet(%{"internet" => persisted}) do
    {:ok, config} = Config.from_persisted(persisted)
    config
  end

  defp tailnet_profile(settings), do: get_in(settings, ["tailnet", "profile_id"])
  defp cluster_group(settings), do: get_in(settings, ["cluster", "group"])

  defp bump(settings, changes) do
    settings
    |> Map.merge(changes)
    |> Map.update!("revision", &(&1 + 1))
    |> touch()
  end

  defp touch(settings) do
    Map.put(
      settings,
      "updated_at",
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    )
  end

  defp normalize_internet(params) do
    params = stringify_keys(params)
    ip_address = params["ip_address"]
    method = params["method"] || if(ip_address in [nil, "", "dhcp"], do: "dhcp", else: "static")

    params
    |> Map.put_new("interface", "eth0")
    |> Map.put_new("kind", "ethernet")
    |> Map.put("method", method)
    |> maybe_put("address", ip_address)
    |> copy_key("dns", "dns_primary")
  end

  defp stringify_keys(params) do
    Map.new(params, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp maybe_put(params, _key, value) when value in [nil, "", "dhcp"], do: params
  defp maybe_put(params, key, value), do: Map.put_new(params, key, value)

  defp copy_key(params, source, destination) do
    case params[source] do
      nil -> params
      value -> Map.put_new(params, destination, value)
    end
  end

  defp validate_auth_token(nil, %{"tailnet" => %{"profile_id" => id}})
       when is_binary(id),
       do: :ok

  defp validate_auth_token(token, _current)
       when is_binary(token) and byte_size(token) in 8..512,
       do: :ok

  defp validate_auth_token(nil, _current), do: {:error, :tailscale_auth_key_required}
  defp validate_auth_token(_token, _current), do: {:error, :invalid_auth_token}

  defp valid_name(name) when is_binary(name) do
    name = String.trim(name)

    if byte_size(name) in 1..80 and String.printable?(name),
      do: {:ok, name},
      else: {:error, :invalid_name}
  end

  defp valid_name(_name), do: {:error, :invalid_name}

  defp blank_nil(nil), do: nil
  defp blank_nil(value) when is_binary(value), do: value |> String.trim() |> empty_nil()
  defp empty_nil(""), do: nil
  defp empty_nil(value), do: value

  defp opposite("a"), do: "b"
  defp opposite("b"), do: "a"

  defp change_id do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp default_ops do
    %{
      internet: &InternetManager.configure/1,
      internet_restore: &InternetManager.restore/1,
      stage_tailnet: &Tailscale.stage_enrollment/3,
      tailnet_restore: &Tailscale.select_profile/1,
      commit_tailnet: &Tailscale.commit_enrollment/1,
      rollback_tailnet: &Tailscale.rollback_enrollment/1,
      poll_tailnet: &Observer.poll_now/0,
      cluster: &ClusterManager.configure/1,
      access: &Access.enable/2,
      disable_access: &Access.disable/0
    }
  end
end

defimpl Inspect, for: NervesGate.Configuration do
  import Inspect.Algebra

  def inspect(state, opts) do
    public = %{
      firmware: state.firmware,
      configured: state.current["configured"],
      revision: state.current["revision"],
      pending: not is_nil(state.pending),
      last_error: state.last_error
    }

    concat(["#NervesGate.Configuration<", to_doc(public, opts), ">"])
  end
end
