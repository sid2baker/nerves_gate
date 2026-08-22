defmodule NervesGate.Cluster.Manager do
  @moduledoc "Owns public cluster groups and distributed Erlang over Tailscale."

  use GenServer

  alias NervesGate.Cluster.Alarms
  alias NervesGate.Cluster.Discovery
  alias NervesGate.Cluster.Distribution
  alias NervesGate.Settings.ChangeControl
  alias NervesGate.Storage.Alarms, as: StorageAlarms
  alias NervesGate.Store
  alias NervesGate.Tailnet.Observer

  @group_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
  @peer_retry 30_000
  @discovery_retry 30_000
  @default_confirmation_timeout :timer.minutes(5)

  defstruct [
    :group,
    :node_name,
    :runtime_ip,
    :timer,
    :root,
    :ops,
    :staged,
    :change_control,
    :confirmation_timer,
    candidates: [],
    connected: MapSet.new(),
    connection_attempts: %{},
    discovery_attempts: %{},
    online: false,
    interval: 5_000,
    confirmation_timeout: @default_confirmation_timeout,
    last_error: nil
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec configure(String.t() | nil, GenServer.server()) :: :ok | {:error, term()}
  def configure(group, server \\ __MODULE__) do
    with {:ok, group} <- validate_group(group) do
      GenServer.call(server, {:configure, fn -> group end}, 10_000)
    end
  end

  @doc "Temporarily applies a group without replacing the persisted group."
  @spec stage(String.t() | nil, String.t(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def stage(group, connection_id, server \\ __MODULE__) when is_binary(connection_id) do
    with {:ok, group} <- validate_group(group) do
      GenServer.call(server, {:stage, group, connection_id}, 10_000)
    end
  end

  @spec confirm(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def confirm(change_id, connection_id, server \\ __MODULE__) do
    GenServer.call(server, {:confirm, change_id, connection_id}, 10_000)
  end

  @spec revert(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def revert(change_id, server \\ __MODULE__) do
    GenServer.call(server, {:revert, change_id}, 10_000)
  end

  @spec reconcile(GenServer.server()) :: :ok
  def reconcile(server \\ __MODULE__), do: GenServer.call(server, :reconcile, 10_000)

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @spec validate_group(term()) :: {:ok, String.t() | nil} | {:error, :invalid_cluster_group}
  def validate_group(value) when value in [nil, ""], do: {:ok, nil}

  def validate_group(value) when is_binary(value) and byte_size(value) in 1..128 do
    value = String.trim(value)

    if byte_size(value) in 1..128 and String.match?(value, @group_pattern),
      do: {:ok, value},
      else: {:error, :invalid_cluster_group}
  end

  def validate_group(_value), do: {:error, :invalid_cluster_group}

  @impl true
  def init(options) do
    root = Keyword.get(options, :root, Store.root())
    {group, storage_error?} = load_group(root)

    state = %__MODULE__{
      root: root,
      group: group,
      ops: Keyword.get(options, :ops, default_ops()),
      change_control: Keyword.get(options, :change_control, ChangeControl),
      interval:
        Keyword.get(
          options,
          :interval,
          Application.get_env(:nerves_gate, :cluster_poll_interval, 5_000)
        ),
      confirmation_timeout:
        Keyword.get(
          options,
          :confirmation_timeout,
          Application.get_env(
            :nerves_gate,
            :settings_confirmation_timeout,
            @default_confirmation_timeout
          )
        )
    }

    if storage_error?, do: StorageAlarms.failure(true)
    Alarms.report(not is_nil(group), false)
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "tailnet")
    if state.change_control.active(:cluster), do: send(self(), :recover_unconfirmed_change)
    send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_call({:configure, _load_group}, _from, %{staged: staged} = state)
      when not is_nil(staged) do
    {:reply, {:error, :settings_change_in_progress}, state}
  end

  def handle_call({:configure, load_group}, _from, state) do
    group = load_group.()

    case Store.write_cluster(group, state.root) do
      :ok ->
        {:reply, :ok, apply_group(state, group)}

      {:error, _reason} ->
        StorageAlarms.failure(true)
        {:reply, {:error, :cluster_persistence_failed}, state}
    end
  end

  def handle_call({:stage, _group, _connection_id}, _from, %{staged: staged} = state)
      when not is_nil(staged) do
    {:reply, {:error, :candidate_in_progress}, state}
  end

  def handle_call({:stage, group, connection_id}, _from, state) do
    id = change_id()

    case state.change_control.begin_change(:cluster, id, self(), connection_id, %{}) do
      :ok ->
        staged = %{
          id: id,
          previous: state.group,
          source_connection: connection_id,
          confirmation_deadline: nil
        }

        state = %{state | staged: staged} |> apply_group(group)

        if is_nil(group) or state.online do
          :ok = state.change_control.awaiting_confirmation(id, %{}, state.confirmation_timeout)

          timer =
            Process.send_after(self(), {:confirmation_timeout, id}, state.confirmation_timeout)

          staged =
            Map.put(
              state.staged,
              :confirmation_deadline,
              System.monotonic_time(:millisecond) + state.confirmation_timeout
            )

          state = %{state | staged: staged, confirmation_timer: timer}
          publish(state)
          {:reply, {:ok, public_staged(staged)}, state}
        else
          reason = state.last_error || :cluster_unavailable
          state = rollback_stage(state, reason)
          {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:confirm, id, connection_id}, _from, %{staged: %{id: id}} = state) do
    if state.staged.source_connection == connection_id do
      {:reply, {:error, :fresh_connection_required}, state}
    else
      case Store.write_cluster(state.group, state.root) do
        :ok ->
          cancel_confirmation_timer(state)
          :ok = state.change_control.finish(id)
          state = %{state | staged: nil, confirmation_timer: nil}
          publish(state)
          {:reply, :ok, state}

        {:error, _reason} ->
          StorageAlarms.failure(true)
          state = rollback_stage(state, :cluster_persistence_failed)
          {:reply, {:error, :cluster_persistence_failed}, state}
      end
    end
  end

  def handle_call({:confirm, _id, _connection_id}, _from, state) do
    {:reply, {:error, :settings_change_not_found}, state}
  end

  def handle_call({:revert, id}, _from, %{staged: %{id: id}} = state) do
    {:reply, :ok, rollback_stage(state, :reverted)}
  end

  def handle_call({:revert, _id}, _from, state) do
    {:reply, {:error, :settings_change_not_found}, state}
  end

  def handle_call(:reconcile, _from, state) do
    {:reply, :ok, reconcile_runtime(state)}
  end

  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  @impl true
  def handle_info(:reconcile, state) do
    state = %{state | timer: nil} |> reconcile_runtime() |> schedule()
    {:noreply, state}
  end

  def handle_info({:tailnet_changed, _status}, state) do
    {:noreply, reconcile_runtime(state)}
  end

  def handle_info({:nodeup, node, _info}, state) do
    state = %{state | connected: MapSet.put(state.connected, node)}
    publish(state)
    {:noreply, state}
  end

  def handle_info({:peer_connection_result, _ipv4, _result}, state) do
    state = %{state | connected: MapSet.new(state.ops.connected.())}
    publish(state)
    {:noreply, state}
  end

  def handle_info({:peer_discovery_result, ipv4, result}, state) do
    candidates =
      Enum.map(state.candidates, fn
        %{ipv4: ^ipv4} = candidate -> apply_discovery_result(candidate, result)
        candidate -> candidate
      end)

    state = %{state | candidates: candidates} |> connect_candidates()
    publish(state)
    {:noreply, state}
  end

  def handle_info({:confirmation_timeout, id}, %{staged: %{id: id}} = state) do
    {:noreply, rollback_stage(state, :confirmation_timeout)}
  end

  def handle_info({:confirmation_timeout, _id}, state), do: {:noreply, state}

  def handle_info(:recover_unconfirmed_change, state) do
    case state.change_control.active(:cluster) do
      %{id: id} ->
        state = apply_group(state, state.group)
        :ok = state.change_control.finish(id, :recovered_unconfirmed_change)
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:nodedown, node, _info}, state) do
    state = %{
      state
      | connected: MapSet.delete(state.connected, node),
        connection_attempts: %{}
    }

    publish(state)
    {:noreply, state}
  end

  defp apply_group(%{group: group} = state, group), do: reconcile_runtime(state)

  defp apply_group(state, group) do
    state
    |> stop_runtime()
    |> Map.put(:group, group)
    |> reconcile_runtime()
  end

  defp rollback_stage(%{staged: nil} = state, _reason), do: state

  defp rollback_stage(%{staged: %{id: id, previous: previous}} = state, reason) do
    cancel_confirmation_timer(state)

    state =
      state
      |> Map.put(:staged, nil)
      |> Map.put(:confirmation_timer, nil)
      |> apply_group(previous)

    :ok = state.change_control.finish(id, reason)
    publish(state)
    state
  end

  defp reconcile_runtime(state) do
    case state.ops.tail_status.() do
      %{online: true, ipv4: ipv4} = tailnet when is_binary(ipv4) ->
        state =
          state
          |> put_candidates(tailnet)
          |> discover_candidates()

        if is_nil(state.group) do
          state = stop_runtime(state)
          Alarms.report(false, false)
          publish(state)
          state
        else
          reconcile_enabled(state, tailnet)
        end

      _blocked ->
        blocked(state)
    end
  end

  defp reconcile_enabled(state, %{ipv4: ipv4} = tailnet) do
    state = put_candidates(state, tailnet)

    state =
      if state.online and state.runtime_ip == ipv4 and state.ops.alive?.() do
        %{state | connected: MapSet.new(state.ops.connected.()), last_error: nil}
      else
        state
        |> stop_runtime()
        |> put_candidates(tailnet)
        |> start_runtime(ipv4)
      end

    state = connect_candidates(state)
    Alarms.report(true, not state.online)
    publish(state)
    state
  end

  defp start_runtime(state, ipv4) do
    # The public group is used as the distributed Erlang cookie. Tailnet grants,
    # rather than secrecy of this value, are the product's distribution boundary.
    cookie = String.to_atom(state.group)

    case state.ops.start.(ipv4, cookie) do
      {:ok, node_name} when is_atom(node_name) ->
        state = %{
          state
          | online: true,
            runtime_ip: ipv4,
            node_name: node_name,
            connected: MapSet.new(state.ops.connected.()),
            last_error: nil
        }

        Alarms.report(true, false)
        publish(state)
        state

      {:error, reason} ->
        state = %{state | last_error: public_error(reason)}
        Alarms.report(true, true)
        publish(state)
        state
    end
  end

  defp blocked(state) do
    state = %{
      stop_runtime(state)
      | candidates: [],
        connection_attempts: %{},
        discovery_attempts: %{}
    }

    Alarms.report(not is_nil(state.group), false)
    publish(state)
    state
  end

  defp stop_runtime(state) do
    if (state.online or state.node_name) || state.ops.alive?.() do
      state.ops.stop.()
    end

    %{
      state
      | online: false,
        runtime_ip: nil,
        node_name: nil,
        connected: MapSet.new(),
        connection_attempts: %{},
        last_error: nil
    }
  end

  defp put_candidates(state, tailnet) do
    previous = Map.new(state.candidates, &{&1.ipv4, &1})

    candidates =
      tailnet
      |> peer_candidates(state.runtime_ip)
      |> Enum.map(fn candidate ->
        case Map.get(previous, candidate.ipv4) do
          nil -> Map.merge(candidate, %{discovered: false, group: nil, discovery_error: nil})
          old -> Map.merge(old, candidate)
        end
      end)

    addresses = MapSet.new(candidates, & &1.ipv4)

    %{
      state
      | candidates: candidates,
        connection_attempts: Map.take(state.connection_attempts, MapSet.to_list(addresses)),
        discovery_attempts: Map.take(state.discovery_attempts, MapSet.to_list(addresses))
    }
  end

  defp peer_candidates(tailnet, local_ipv4) do
    tailnet
    |> Map.get(:nodes, [])
    |> Enum.filter(fn candidate ->
      Map.get(candidate, :self, false) == false and Map.get(candidate, :online, false) and
        is_binary(Map.get(candidate, :ipv4)) and Map.get(candidate, :ipv4) != local_ipv4 and
        gateway_hostname?(Map.get(candidate, :hostname))
    end)
    |> Enum.map(fn candidate ->
      ipv4 = Map.fetch!(candidate, :ipv4)

      %{
        hostname: Map.get(candidate, :hostname),
        ipv4: ipv4,
        node: "nervesgate@#{ipv4}"
      }
    end)
    |> Enum.uniq_by(& &1.ipv4)
    |> Enum.sort_by(&{&1.hostname || "", &1.ipv4})
  end

  defp gateway_hostname?("nervesgate-" <> _rest), do: true
  defp gateway_hostname?(_hostname), do: false

  defp discover_candidates(state) do
    now = System.monotonic_time(:millisecond)
    owner = self()

    Enum.reduce(state.candidates, state, fn candidate, state ->
      retry_pending? = retry_pending?(state.discovery_attempts, candidate.ipv4, now)

      if retry_pending? do
        state
      else
        launch_discovery(owner, state.ops.discover, candidate.ipv4)

        %{
          state
          | discovery_attempts:
              Map.put(state.discovery_attempts, candidate.ipv4, now + @discovery_retry)
        }
      end
    end)
  end

  defp retry_pending?(attempts, ipv4, now) do
    case Map.get(attempts, ipv4) do
      nil -> false
      next_attempt -> next_attempt > now
    end
  end

  defp apply_discovery_result(candidate, {:ok, group}) do
    %{candidate | discovered: true, group: group, discovery_error: nil}
  end

  defp apply_discovery_result(candidate, {:error, reason}) do
    %{candidate | discovered: false, group: nil, discovery_error: public_error(reason)}
  end

  defp apply_discovery_result(candidate, _invalid) do
    %{candidate | discovered: false, group: nil, discovery_error: :discovery_failed}
  end

  defp connect_candidates(%{online: false} = state), do: state

  defp connect_candidates(state) do
    now = System.monotonic_time(:millisecond)
    connected = MapSet.new(state.ops.connected.(), &to_string/1)
    owner = self()

    state =
      state.candidates
      |> Enum.filter(&(&1.discovered and &1.group == state.group))
      |> Enum.reduce(state, fn candidate, state ->
        retry_pending? = retry_pending?(state.connection_attempts, candidate.ipv4, now)

        if MapSet.member?(connected, candidate.node) or retry_pending? do
          state
        else
          launch_connect(owner, state.ops.connect, candidate.ipv4)

          %{
            state
            | connection_attempts:
                Map.put(state.connection_attempts, candidate.ipv4, now + @peer_retry)
          }
        end
      end)

    %{state | connected: MapSet.new(state.ops.connected.())}
  end

  defp public_status(state) do
    online = state.online and state.ops.alive?.()
    connected = if online, do: state.connected |> MapSet.to_list() |> Enum.sort(), else: []
    connected_names = MapSet.new(connected, &to_string/1)

    candidates =
      Enum.map(state.candidates, fn candidate ->
        Map.put(candidate, :connected, MapSet.member?(connected_names, candidate.node))
      end)

    %{
      enabled: not is_nil(state.group),
      group: state.group,
      online: online,
      node: if(online, do: state.node_name),
      connected: connected,
      candidates: candidates,
      groups: available_groups(state.group, candidates),
      staged: not is_nil(state.staged),
      pending: public_pending(state.staged)
    }
  end

  defp available_groups(local_group, candidates) do
    members =
      if(local_group, do: [%{group: local_group, connected: true, self: true}], else: []) ++
        for(
          %{discovered: true, group: group} = candidate <- candidates,
          is_binary(group),
          do: %{group: group, connected: candidate.connected, self: false}
        )

    members
    |> Enum.group_by(& &1.group)
    |> Enum.map(fn {name, group_members} ->
      %{
        name: name,
        members: length(group_members),
        connected: Enum.count(group_members, & &1.connected),
        active: name == local_group
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp public_pending(nil), do: nil

  defp public_pending(%{confirmation_deadline: nil, id: id}),
    do: %{id: id, phase: :applying, remaining_seconds: nil}

  defp public_pending(staged), do: public_staged(staged)

  defp public_staged(staged) do
    %{
      id: staged.id,
      phase: :awaiting_confirmation,
      remaining_seconds:
        max(
          0,
          div(staged.confirmation_deadline - System.monotonic_time(:millisecond) + 999, 1_000)
        )
    }
  end

  defp cancel_confirmation_timer(%{confirmation_timer: nil}), do: :ok
  defp cancel_confirmation_timer(state), do: Process.cancel_timer(state.confirmation_timer)

  defp change_id do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp publish(state) do
    status = public_status(state)
    Phoenix.PubSub.local_broadcast(NervesGate.PubSub, "cluster", {:cluster_changed, status})
  end

  defp load_group(root) do
    case Store.read_cluster(root) do
      {:ok, group} -> {group, false}
      {:error, _reason} -> {nil, true}
    end
  end

  defp launch_connect(owner, connect, ipv4) do
    Task.Supervisor.start_child(NervesGate.TaskSupervisor, fn ->
      send(owner, {:peer_connection_result, ipv4, connect.(ipv4)})
    end)
  end

  defp launch_discovery(owner, discover, ipv4) do
    Task.Supervisor.start_child(NervesGate.TaskSupervisor, fn ->
      send(owner, {:peer_discovery_result, ipv4, discover.(ipv4)})
    end)
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :reconcile, state.interval)}
  end

  defp public_error(reason) when is_atom(reason), do: reason
  defp public_error(_reason), do: :operation_failed

  defp default_ops do
    %{
      tail_status: &Observer.status/0,
      start: &Distribution.start/2,
      stop: &Distribution.stop/0,
      alive?: &Distribution.alive?/0,
      connect: &Distribution.connect/1,
      connected: &Distribution.connected/0,
      discover: &Discovery.fetch/1
    }
  end
end

defimpl Inspect, for: NervesGate.Cluster.Manager do
  import Inspect.Algebra

  def inspect(state, opts) do
    public = %{
      group: state.group,
      online: state.online,
      node: state.node_name,
      connected: MapSet.size(state.connected),
      last_error: state.last_error
    }

    concat(["#NervesGate.Cluster.Manager<", to_doc(public, opts), ">"])
  end
end
