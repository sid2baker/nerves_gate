defmodule NervesGate.Cluster.TailscaleStrategy do
  @moduledoc "libcluster strategy fed exclusively by normalized Tailscale observations."

  use GenServer
  use Cluster.Strategy

  alias Cluster.Strategy.State
  alias NervesGate.Backoff

  @initial_retry 1_000
  @maximum_retry 30_000

  @impl true
  def start_link([%State{} = strategy_state]) do
    GenServer.start_link(__MODULE__, strategy_state)
  end

  @impl true
  def init(strategy_state) do
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "tailscale")
    desired = NervesGate.Tailscale.Observer.candidates()
    connect(strategy_state, desired)
    {:ok, %{strategy: strategy_state, desired: desired, retry: @initial_retry}, @initial_retry}
  end

  @impl true
  def handle_info(:timeout, state), do: retry_connections(state)
  def handle_info(:retry, state), do: retry_connections(state)

  def handle_info({:tailscale_changed, status}, state) do
    removed =
      MapSet.difference(MapSet.new(state.desired), MapSet.new(status.candidates))
      |> MapSet.to_list()

    disconnect(state.strategy, removed)
    connect(state.strategy, status.candidates)
    {:noreply, %{state | desired: status.candidates, retry: @initial_retry}, @initial_retry}
  end

  defp retry_connections(state) do
    connect(state.strategy, state.desired)
    {wait, next_retry} = Backoff.next(state.retry, @maximum_retry)
    {:noreply, %{state | retry: next_retry}, wait}
  end

  defp connect(strategy, nodes) do
    Cluster.Strategy.connect_nodes(
      strategy.topology,
      strategy.connect,
      strategy.list_nodes,
      nodes
    )
  end

  defp disconnect(strategy, nodes) do
    Cluster.Strategy.disconnect_nodes(
      strategy.topology,
      strategy.disconnect,
      strategy.list_nodes,
      nodes
    )
  end
end
