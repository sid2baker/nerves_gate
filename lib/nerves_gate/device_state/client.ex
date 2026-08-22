defmodule NervesGate.DeviceState.Client do
  @moduledoc """
  Keeps local `%DeviceState.Data{}` copies for already-connected gateways.

  Canonical data is stored separately from replication transport metadata.
  This process never discovers or connects peers. It only joins authoritative
  servers on BEAM nodes that are already connected.
  """

  use GenServer

  alias NervesGate.DeviceState.Data
  alias NervesGate.DeviceState.Server

  @max_buffered_operations 100

  defstruct data: %{},
            metadata: %{},
            pending: MapSet.new(),
            buffered: %{},
            server_monitors: %{},
            retries: %{},
            monitoring_nodes: false

  @type metadata :: %{
          boot_id: String.t(),
          revision: non_neg_integer(),
          connected: boolean(),
          last_seen_at: DateTime.t()
        }

  @type replica :: %{
          data: Data.t(),
          node: node(),
          boot_id: String.t(),
          revision: non_neg_integer(),
          connected: boolean(),
          last_seen_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec replicas(GenServer.server()) :: %{String.t() => replica()}
  def replicas(server \\ __MODULE__), do: GenServer.call(server, :replicas)

  @spec get(String.t(), GenServer.server()) :: replica() | nil
  def get(device_id, server \\ __MODULE__) do
    server |> replicas() |> Map.get(device_id)
  end

  @spec data(String.t(), GenServer.server()) :: Data.t() | nil
  def data(device_id, server \\ __MODULE__) do
    case get(device_id, server) do
      %{data: data} -> data
      nil -> nil
    end
  end

  @impl true
  def init(options) do
    if Keyword.get(options, :subscribe, true) do
      Phoenix.PubSub.subscribe(NervesGate.PubSub, "cluster")
    end

    state =
      if Keyword.get(options, :monitor_nodes, true),
        do: ensure_node_monitoring(%__MODULE__{}),
        else: %__MODULE__{}

    if Keyword.get(options, :sync_connected, true), do: send(self(), :sync_connected)
    {:ok, state}
  end

  @impl true
  def handle_call(:replicas, _from, state) do
    replicas =
      Map.new(state.data, fn {node, data} ->
        {data.device_id, replica(node, data, Map.fetch!(state.metadata, node))}
      end)

    {:reply, replicas, state}
  end

  @impl true
  def handle_info(:sync_connected, state) do
    state = Enum.reduce(Node.list(:connected), state, &start_join(&2, &1))
    {:noreply, state}
  end

  def handle_info({:nodeup, node, _info}, state), do: {:noreply, start_join(state, node)}

  def handle_info({:nodedown, node, _info}, state) do
    {:noreply, state |> mark_disconnected(node) |> clear_retry(node)}
  end

  def handle_info({:cluster_changed, %{online: true}}, state) do
    state = ensure_node_monitoring(state)
    send(self(), :sync_connected)
    {:noreply, state}
  end

  def handle_info({:cluster_changed, %{online: false}}, state) do
    state =
      state.data
      |> Map.keys()
      |> Enum.reduce(%{state | monitoring_nodes: false}, &mark_disconnected(&2, &1))
      |> Map.put(:retries, %{})

    {:noreply, state}
  end

  def handle_info({:join_node, node, retry}, state) do
    state = if Map.get(state.retries, node) == retry, do: start_join(state, node), else: state
    {:noreply, state}
  end

  def handle_info(
        {:device_state_joined, node,
         {:ok, %{boot_id: boot_id, revision: revision, data: %Data{} = data}}},
        state
      ) do
    snapshot = %{boot_id: boot_id, revision: revision, data: data}
    {:noreply, install_snapshot(state, node, snapshot)}
  end

  def handle_info({:device_state_joined, node, _error}, state) do
    state = state |> clear_pending(node) |> mark_disconnected(node) |> schedule_retry(node)
    {:noreply, state}
  end

  def handle_info(
        {:device_state_operation, node, boot_id, revision, operation},
        state
      ) do
    {:noreply, receive_operation(state, node, boot_id, revision, operation)}
  end

  def handle_info({:DOWN, reference, :process, _object, _reason}, state) do
    case Map.pop(state.server_monitors, reference) do
      {nil, _monitors} ->
        {:noreply, state}

      {node, monitors} ->
        state =
          %{state | server_monitors: monitors}
          |> mark_disconnected(node)
          |> schedule_retry(node)

        {:noreply, state}
    end
  end

  defp receive_operation(state, node, boot_id, revision, operation) do
    if MapSet.member?(state.pending, node) do
      buffer_operation(state, node, {boot_id, revision, operation})
    else
      apply_or_join(state, node, boot_id, revision, operation)
    end
  end

  defp apply_or_join(state, node, boot_id, revision, operation) do
    with {:ok, data} <- Map.fetch(state.data, node),
         {:ok, metadata} <- Map.fetch(state.metadata, node) do
      apply_to_replica(state, node, data, metadata, boot_id, revision, operation)
    else
      :error ->
        state
        |> buffer_operation(node, {boot_id, revision, operation})
        |> start_join(node)
    end
  end

  defp apply_to_replica(state, node, data, metadata, boot_id, revision, operation) do
    case apply_remote_operation(data, metadata, boot_id, revision, operation) do
      {:ok, data, metadata} ->
        put_replica(state, node, data, metadata)

      :duplicate ->
        state

      :resync ->
        state
        |> mark_disconnected(node)
        |> buffer_operation(node, {boot_id, revision, operation})
        |> start_join(node)
    end
  end

  defp apply_remote_operation(data, metadata, boot_id, revision, operation) do
    cond do
      boot_id != metadata.boot_id ->
        :resync

      revision <= metadata.revision ->
        :duplicate

      revision != metadata.revision + 1 ->
        :resync

      true ->
        apply_ordered_operation(data, metadata, revision, operation)
    end
  end

  defp apply_ordered_operation(data, metadata, revision, operation) do
    case Data.apply_operation(data, operation) do
      {:ok, data, _actions} ->
        metadata = %{metadata | revision: revision, connected: true, last_seen_at: now()}
        {:ok, data, metadata}

      :error ->
        :resync
    end
  end

  defp start_join(state, remote_node) do
    if remote_node == Node.self(), do: state, else: do_start_join(state, remote_node)
  end

  defp do_start_join(state, node) do
    if MapSet.member?(state.pending, node), do: state, else: launch_join(state, node)
  end

  defp launch_join(state, node) do
    owner = self()

    case Task.Supervisor.start_child(NervesGate.TaskSupervisor, fn ->
           complete_join(node, owner)
         end) do
      {:ok, _pid} -> %{state | pending: MapSet.put(state.pending, node)}
      {:error, _reason} -> state |> mark_disconnected(node) |> schedule_retry(node)
    end
  end

  defp complete_join(node, owner) do
    send(owner, {:device_state_joined, node, remote_join(node, owner)})
  end

  defp remote_join(node, client) do
    Server.join(client, {Server, node})
  catch
    :exit, reason -> {:error, reason}
  end

  defp install_snapshot(state, node, snapshot) do
    metadata = %{
      boot_id: snapshot.boot_id,
      revision: snapshot.revision,
      connected: true,
      last_seen_at: now()
    }

    state =
      state
      |> clear_pending(node)
      |> clear_retry(node)
      |> monitor_remote_server(node)
      |> put_replica(node, snapshot.data, metadata)

    buffered = state.buffered |> Map.get(node, []) |> Enum.sort_by(&elem(&1, 1))
    state = %{state | buffered: Map.delete(state.buffered, node)}

    Enum.reduce_while(buffered, state, fn {boot_id, revision, operation}, state ->
      case apply_buffered_operation(state, node, boot_id, revision, operation) do
        {:ok, state} -> {:cont, state}
        :resync -> {:halt, state |> mark_disconnected(node) |> start_join(node)}
      end
    end)
  end

  defp apply_buffered_operation(state, node, boot_id, revision, operation) do
    data = Map.fetch!(state.data, node)
    metadata = Map.fetch!(state.metadata, node)

    case apply_remote_operation(data, metadata, boot_id, revision, operation) do
      {:ok, data, metadata} -> {:ok, put_replica(state, node, data, metadata)}
      :duplicate -> {:ok, state}
      :resync -> :resync
    end
  end

  defp put_replica(state, node, data, metadata) do
    duplicate_nodes =
      for {other_node, other_data} <- state.data,
          other_node != node and other_data.device_id == data.device_id,
          do: other_node

    state = %{
      state
      | data: state.data |> Map.drop(duplicate_nodes) |> Map.put(node, data),
        metadata: state.metadata |> Map.drop(duplicate_nodes) |> Map.put(node, metadata)
    }

    Phoenix.PubSub.local_broadcast(
      NervesGate.PubSub,
      "device_state",
      {:replica_changed, data.device_id, replica(node, data, metadata)}
    )

    state
  end

  defp mark_disconnected(state, node) do
    state = clear_pending(state, node)

    case Map.fetch(state.metadata, node) do
      {:ok, %{connected: true} = metadata} ->
        put_replica(state, node, Map.fetch!(state.data, node), %{metadata | connected: false})

      _missing_or_stale ->
        state
    end
  end

  defp clear_pending(state, node) do
    %{state | pending: MapSet.delete(state.pending, node)}
  end

  defp schedule_retry(state, node) do
    if node in Node.list(:connected) do
      retry = Map.get(state.retries, node, 1_000)
      {wait, next_retry} = NervesGate.Backoff.next(retry, 30_000)
      Process.send_after(self(), {:join_node, node, next_retry}, wait)
      %{state | retries: Map.put(state.retries, node, next_retry)}
    else
      state
    end
  end

  defp clear_retry(state, node), do: %{state | retries: Map.delete(state.retries, node)}

  defp buffer_operation(state, node, operation) do
    buffered =
      state.buffered
      |> Map.get(node, [])
      |> then(&[operation | &1])
      |> Enum.take(@max_buffered_operations)

    %{state | buffered: Map.put(state.buffered, node, buffered)}
  end

  defp monitor_remote_server(state, node) do
    {old_references, remaining} =
      Enum.split_with(state.server_monitors, fn {_reference, monitored_node} ->
        monitored_node == node
      end)

    Enum.each(old_references, fn {reference, _node} -> Process.demonitor(reference, [:flush]) end)
    reference = Process.monitor({Server, node})
    %{state | server_monitors: Map.put(Map.new(remaining), reference, node)}
  end

  defp ensure_node_monitoring(%{monitoring_nodes: true} = state), do: state

  defp ensure_node_monitoring(state) do
    if Node.alive?() do
      :net_kernel.monitor_nodes(true, node_type: :visible, nodedown_reason: true)
      %{state | monitoring_nodes: true}
    else
      state
    end
  end

  defp replica(node, data, metadata) do
    Map.merge(metadata, %{node: node, data: data})
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond)
end
