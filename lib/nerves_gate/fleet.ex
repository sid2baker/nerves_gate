defmodule NervesGate.Fleet do
  @moduledoc """
  Owns replication of every connected remote gateway.

  The process observes connected Erlang nodes, atomically subscribes to each
  remote DeviceState stream, and stores one pure `DeviceState.Client` reducer
  per node. A single bounded timer handles leases and resubscription; no
  scanner, registry, dynamic supervisor, or process-per-peer is required.
  """

  use GenServer

  alias NervesGate.DeviceState.Client
  alias NervesGate.DeviceState.Server
  alias NervesGate.Subscribers

  @tick_interval 1_000
  @lease_timeout 2_500
  @retry_delay 1_000
  @max_retry 30_000

  defstruct boot_id: nil,
            revision: 0,
            entries: %{},
            replicas: %{},
            subscribers: %{},
            sync_tasks: %{},
            connected_nodes: nil,
            subscribe_remote: nil,
            start_task: nil,
            clock: nil,
            wall_clock: nil,
            tick_interval: @tick_interval,
            lease_timeout: @lease_timeout,
            retry_delay: @retry_delay,
            max_sync_tasks: 4

  @type replica :: %{
          state: NervesGate.DeviceState.State.t(),
          node: node(),
          boot_id: String.t(),
          revision: non_neg_integer(),
          connected: boolean(),
          last_seen_at: DateTime.t() | nil
        }

  @type snapshot :: %{
          boot_id: String.t(),
          revision: non_neg_integer(),
          replicas: %{String.t() => replica()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec subscribe(pid(), GenServer.server()) :: {:ok, snapshot()}
  def subscribe(subscriber \\ self(), server \\ __MODULE__) when is_pid(subscriber),
    do: GenServer.call(server, {:subscribe, subscriber})

  @spec unsubscribe(pid(), GenServer.server()) :: :ok
  def unsubscribe(subscriber \\ self(), server \\ __MODULE__) when is_pid(subscriber),
    do: GenServer.call(server, {:unsubscribe, subscriber})

  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @spec replicas(GenServer.server()) :: %{String.t() => replica()}
  def replicas(server \\ __MODULE__), do: snapshot(server).replicas

  @spec diagnostics(GenServer.server()) :: %{node() => map()}
  def diagnostics(server \\ __MODULE__), do: GenServer.call(server, :diagnostics)

  @impl true
  def init(options) do
    state = %__MODULE__{
      boot_id: Keyword.get_lazy(options, :boot_id, &new_boot_id/0),
      connected_nodes: Keyword.get(options, :connected_nodes, &Node.list/0),
      subscribe_remote: Keyword.get(options, :subscribe_remote, &remote_subscribe/2),
      start_task:
        Keyword.get(options, :start_task, fn function ->
          Task.Supervisor.async_nolink(NervesGate.TaskSupervisor, function)
        end),
      clock: Keyword.get(options, :clock, fn -> System.monotonic_time(:millisecond) end),
      wall_clock:
        Keyword.get(options, :wall_clock, fn ->
          DateTime.utc_now() |> DateTime.truncate(:millisecond)
        end),
      tick_interval: Keyword.get(options, :tick_interval, @tick_interval),
      lease_timeout: Keyword.get(options, :lease_timeout, @lease_timeout),
      retry_delay: Keyword.get(options, :retry_delay, @retry_delay),
      max_sync_tasks: Keyword.get(options, :max_sync_tasks, 4)
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) do
    state = %{state | subscribers: Subscribers.add(state.subscribers, subscriber)}
    {:reply, {:ok, snapshot_from(state)}, state}
  end

  def handle_call({:unsubscribe, subscriber}, _from, state) do
    subscribers = Subscribers.remove(state.subscribers, subscriber)
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_from(state), state}

  def handle_call(:diagnostics, _from, state) do
    diagnostics =
      Map.new(state.entries, fn {node, entry} ->
        {node,
         %{
           connected: entry.connected,
           synced: entry.synced,
           revision: entry.client && entry.client.revision,
           boot_id: entry.client && entry.client.boot_id,
           blocked_by: entry.blocked_by,
           last_error: entry.last_error,
           attempt: entry.attempt,
           retry_at: entry.retry_at
         }}
      end)

    {:reply, diagnostics, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state =
      state
      |> observe_nodes()
      |> expire_leases()
      |> reconcile_replicas()
      |> start_synchronizations()

    schedule_tick(state)
    {:noreply, state}
  end

  def handle_info(
        {:device_state_operation, remote_node, _boot, _revision, _operation} = message,
        state
      ) do
    case Map.fetch(state.entries, remote_node) do
      {:ok, %{synced: true, client: %Client{} = client} = entry} ->
        case Client.reduce(client, message) do
          {:ok, client, :changed} ->
            entry = entry |> Map.put(:client, client) |> connected(state)
            {:noreply, state |> put_entry(entry) |> reconcile_replicas()}

          {:ok, _client, :duplicate} ->
            {:noreply, put_entry(state, touch(entry, state))}

          :resync ->
            {:noreply,
             state |> put_entry(require_sync(entry, :revision_gap)) |> reconcile_replicas()}
        end

      _unknown_or_unsynced ->
        {:noreply, state}
    end
  end

  def handle_info({:device_state_heartbeat, remote_node, _boot, _revision} = message, state) do
    case Map.fetch(state.entries, remote_node) do
      {:ok, %{synced: true, client: %Client{} = client} = entry} ->
        case Client.heartbeat(client, message) do
          {:ok, _client} ->
            {:noreply, put_entry(state, touch(entry, state))}

          :resync ->
            {:noreply,
             state
             |> put_entry(require_sync(entry, :boot_or_revision_changed))
             |> reconcile_replicas()}
        end

      _unknown_or_unsynced ->
        {:noreply, state}
    end
  end

  def handle_info({reference, result}, state) when is_reference(reference) do
    case Map.pop(state.sync_tasks, reference) do
      {nil, _tasks} ->
        {:noreply, state}

      {%{node: remote_node}, tasks} ->
        Process.demonitor(reference, [:flush])
        state = %{state | sync_tasks: tasks}

        {:noreply,
         state
         |> complete_synchronization(remote_node, reference, result)
         |> reconcile_replicas()}
    end
  end

  def handle_info({:DOWN, reference, :process, process, reason}, state) do
    case Map.pop(state.sync_tasks, reference) do
      {%{node: remote_node}, tasks} ->
        state = %{state | sync_tasks: tasks}
        entry = Map.fetch!(state.entries, remote_node)

        state =
          if entry.sync_ref == reference,
            do: put_entry(state, retry(entry, public_error(reason), state)),
            else: state

        {:noreply, reconcile_replicas(state)}

      {nil, _tasks} ->
        subscribers = Subscribers.down(state.subscribers, process, reference)
        {:noreply, %{state | subscribers: subscribers}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp observe_nodes(state) do
    connected = state.connected_nodes.() |> Enum.reject(&(&1 == node())) |> MapSet.new()

    entries =
      Enum.reduce(connected, state.entries, fn remote_node, entries ->
        Map.put_new(entries, remote_node, new_entry(remote_node))
      end)

    entries =
      Map.new(entries, fn {remote_node, entry} ->
        if MapSet.member?(connected, remote_node) do
          {remote_node, %{entry | transport_connected: true}}
        else
          {remote_node,
           %{
             entry
             | transport_connected: false,
               connected: false,
               synced: false,
               blocked_by: :node,
               retry_at: nil
           }}
        end
      end)

    %{state | entries: entries}
  catch
    _kind, _reason -> state
  end

  defp expire_leases(state) do
    entries =
      Map.new(state.entries, fn {node, entry} ->
        if entry.synced and lease_expired?(entry, state) do
          {node, require_sync(entry, :heartbeat_timeout)}
        else
          {node, entry}
        end
      end)

    %{state | entries: entries}
  end

  # Remote calls run in bounded unlinked tasks. One unreachable node cannot
  # block Fleet calls or operation reduction for every other node.
  defp start_synchronizations(state) do
    available = max(0, state.max_sync_tasks - map_size(state.sync_tasks))

    state.entries
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&sync_due?(&1, state))
    |> Enum.take(available)
    |> Enum.reduce(state, &start_synchronization/2)
  end

  defp start_synchronization(entry, state) do
    subscriber = self()
    subscribe_remote = state.subscribe_remote

    task =
      state.start_task.(fn ->
        try do
          subscribe_remote.(entry.node, subscriber)
        catch
          :exit, reason -> {:error, reason}
        end
      end)

    entry = %{entry | sync_ref: task.ref, blocked_by: :subscription}
    state = put_entry(state, entry)
    %{state | sync_tasks: Map.put(state.sync_tasks, task.ref, %{node: entry.node, pid: task.pid})}
  catch
    _kind, reason -> put_entry(state, retry(entry, public_error(reason), state))
  end

  defp complete_synchronization(state, remote_node, reference, result) do
    entry = Map.fetch!(state.entries, remote_node)

    cond do
      entry.sync_ref != reference ->
        state

      not entry.transport_connected ->
        put_entry(state, %{entry | sync_ref: nil})

      true ->
        install_synchronization(state, entry, result)
    end
  end

  defp install_synchronization(state, entry, {:ok, snapshot}) do
    case Client.install(snapshot) do
      {:ok, client} ->
        entry = entry |> Map.put(:client, client) |> connected(state)
        put_entry(state, entry)

      :error ->
        put_entry(state, retry(entry, :invalid_snapshot, state))
    end
  end

  defp install_synchronization(state, entry, {:error, reason}),
    do: put_entry(state, retry(entry, public_error(reason), state))

  defp install_synchronization(state, entry, _invalid),
    do: put_entry(state, retry(entry, :invalid_snapshot, state))

  defp reconcile_replicas(state) do
    replicas = replicas_from_entries(state.entries)

    operations =
      for({id, _replica} <- state.replicas, not Map.has_key?(replicas, id), do: {:delete, id}) ++
        for(
          {id, replica} <- replicas,
          Map.get(state.replicas, id) != replica,
          do: {:put, id, replica}
        )

    Enum.reduce(operations, %{state | replicas: replicas}, &broadcast_operation/2)
  end

  defp replicas_from_entries(entries) do
    entries
    |> Enum.map(fn {_node, entry} -> public_replica(entry) end)
    |> Enum.reject(&is_nil/1)
    |> Map.new(fn replica -> {replica.state.device.device_id, replica} end)
  end

  defp public_replica(%{client: %Client{state: %{device: %{device_id: id}}} = client} = entry)
       when is_binary(id) do
    %{
      state: client.state,
      node: entry.node,
      boot_id: client.boot_id,
      revision: client.revision,
      connected: entry.connected,
      last_seen_at: entry.last_seen_at
    }
  end

  defp public_replica(_entry), do: nil

  defp broadcast_operation(operation, state) do
    revision = state.revision + 1
    message = {:fleet_operation, state.boot_id, revision, operation}
    Enum.each(state.subscribers, fn {subscriber, _metadata} -> send(subscriber, message) end)
    %{state | revision: revision}
  end

  defp new_entry(node) do
    %{
      node: node,
      client: nil,
      transport_connected: true,
      connected: false,
      synced: false,
      last_received_at: nil,
      last_seen_at: nil,
      blocked_by: nil,
      last_error: nil,
      attempt: 0,
      retry_at: nil,
      sync_ref: nil
    }
  end

  defp connected(entry, state) do
    entry
    |> Map.merge(%{
      connected: true,
      synced: true,
      blocked_by: nil,
      last_error: nil,
      attempt: 0,
      retry_at: nil,
      sync_ref: nil
    })
    |> touch(state)
  end

  defp require_sync(entry, reason) do
    %{
      entry
      | connected: false,
        synced: false,
        blocked_by: if(reason == :heartbeat_timeout, do: :heartbeat, else: :state),
        last_error: reason,
        retry_at: nil,
        sync_ref: nil
    }
  end

  defp retry(entry, reason, state) do
    attempt = entry.attempt + 1
    wait = min(state.retry_delay * attempt, @max_retry)

    %{
      entry
      | connected: false,
        synced: false,
        blocked_by: :subscription,
        last_error: reason,
        attempt: attempt,
        retry_at: now(state) + wait,
        sync_ref: nil
    }
  end

  defp touch(entry, state) do
    %{entry | last_received_at: now(state), last_seen_at: state.wall_clock.()}
  end

  defp sync_due?(entry, state) do
    entry.transport_connected and not entry.synced and is_nil(entry.sync_ref) and
      (is_nil(entry.retry_at) or now(state) >= entry.retry_at)
  end

  defp lease_expired?(%{last_received_at: nil}, _state), do: true

  defp lease_expired?(entry, state),
    do: now(state) - entry.last_received_at >= state.lease_timeout

  defp now(state), do: state.clock.()

  defp put_entry(state, entry), do: put_in(state.entries[entry.node], entry)

  defp snapshot_from(state) do
    %{boot_id: state.boot_id, revision: state.revision, replicas: state.replicas}
  end

  defp schedule_tick(state), do: Process.send_after(self(), :tick, state.tick_interval)

  defp remote_subscribe(remote_node, subscriber) do
    Server.subscribe_remote(subscriber, {Server, remote_node}, 1_000)
  catch
    :exit, reason -> {:error, reason}
  end

  defp public_error(reason) when is_atom(reason), do: reason
  defp public_error(_reason), do: :remote_state_unavailable

  defp new_boot_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
