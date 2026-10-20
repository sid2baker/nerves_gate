defmodule NervesGate.ProjectionServer do
  @moduledoc """
  One device-owned UI read model, not a command coordinator.

  Subscribe is a serialized call: the caller is registered before receiving the
  snapshot. Later operations come directly from this same PID, in order. Clients
  monitor it and subscribe afresh after a restart or a distribution disconnect.
  Property payloads are only invalidation hints, never reducer operations.
  """
  use GenServer
  alias NervesGate.Projection

  @domains [:network, :remote, :equipment, :indicators, :buses, :ssh, :storage]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # Call directly even across nodes, not inside an ephemeral RPC process.
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, :subscribe)
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(_) do
    bind()
    inputs = Map.new([:system | @domains], &{&1, NervesGate.status_input(&1)})
    {:ok, %{projection: Projection.new(inputs), clients: %{}, dirty: MapSet.new()}}
  end

  @impl true
  def handle_call(:subscribe, {pid, _}, state) do
    if ref = state.clients[pid], do: Process.demonitor(ref, [:flush])
    clients = Map.put(state.clients, pid, Process.monitor(pid))
    {:reply, {:ok, self(), state.projection}, %{state | clients: clients}}
  end

  def handle_call(:snapshot, _, state), do: {:reply, state.projection, state}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    clients =
      if state.clients[pid] == ref, do: Map.delete(state.clients, pid), else: state.clients

    {:noreply, %{state | clients: clients}}
  end

  def handle_info(:subscribe, state) do
    bind()
    {:noreply, dirty(state, @domains)}
  end

  def handle_info(:refresh, state) do
    state = Enum.reduce([:system | MapSet.to_list(state.dirty)], state, &refresh/2)
    {:noreply, %{state | dirty: MapSet.new()}}
  end

  def handle_info(%PropertyTable.Event{table: table, property: path}, state),
    do: {:noreply, dirty(state, domains(table, path))}

  def handle_info({table, path, _, _, _}, state),
    do: {:noreply, dirty(state, domains(table, path))}

  def handle_info(_, state), do: {:noreply, state}

  defp bind do
    case NervesGate.subscribe() do
      :ok -> :ok
      {:error, _} -> Process.send_after(self(), :subscribe, 1_000)
    end
  end

  defp domains(NervesGate.Properties, [name | _]) do
    case Enum.find(@domains, &(Atom.to_string(&1) == name)) do
      # Network's sharing admission also reads remote state.
      :remote -> [:remote, :network]
      nil -> []
      domain -> [domain]
    end
  end

  defp domains(VintageNet, _), do: [:network]
  defp domains(Tailscaled, _), do: [:remote, :network]
  defp domains(_, _), do: []

  defp dirty(state, []), do: state

  defp dirty(state, domains) do
    if MapSet.size(state.dirty) == 0, do: Process.send_after(self(), :refresh, 20)
    %{state | dirty: Enum.reduce(domains, state.dirty, &MapSet.put(&2, &1))}
  end

  defp refresh(domain, state) do
    value = NervesGate.status_input(domain)

    if value == Map.fetch!(state.projection.inputs, domain) do
      state
    else
      operation = {:replace, domain, value}
      projection = Projection.apply(state.projection, operation)
      for {pid, _} <- state.clients, do: send(pid, {:projection, self(), operation})
      %{state | projection: projection}
    end
  end
end
