defmodule NervesGate.TestNetworkAdapter do
  @moduledoc false
  use Agent
  @behaviour NervesGate.Network.Adapter
  alias NervesGate.Network.Host

  def start_link(opts) do
    Agent.start_link(fn ->
      %{
        host: opts[:host],
        owner: opts[:owner],
        failures: %{},
        holds: %{},
        crashes: %{},
        calls: []
      }
    end)
  end

  def fail(server, operation, reason),
    do: Agent.update(server, &put_in(&1, [:failures, operation], reason))

  def hold(server, operation, network),
    do: Agent.update(server, &put_in(&1, [:holds, operation], network))

  def crash(server, operation, network),
    do: Agent.update(server, &put_in(&1, [:crashes, operation], network))

  def calls(server), do: Agent.get(server, &Enum.reverse(&1.calls))

  @impl true
  def load(server), do: call(server, :load, nil, &Host.load/1)
  @impl true
  def save(network, server), do: call(server, :save, network, &Host.save(network, &1))
  @impl true
  def apply_config(network, server),
    do: call(server, :apply, network, &Host.apply_config(network, &1))

  @impl true
  def restore(network, server), do: apply_config(network, server)

  @impl true
  def snapshot(server) do
    state = Agent.get(server, & &1)
    if state.failures[:snapshot], do: nil, else: Host.snapshot(state.host)
  end

  @impl true
  def observations(server), do: Host.observations(Agent.get(server, & &1.host))

  defp call(server, operation, network, fun) do
    state = Agent.get_and_update(server, &{&1, %{&1 | calls: [{operation, network} | &1.calls]}})

    if Map.has_key?(state.holds, operation) and state.holds[operation] == network do
      send(state.owner, {:blocked, operation, self()})

      receive do
        :continue -> :ok
      end
    end

    if Map.has_key?(state.crashes, operation) and state.crashes[operation] == network,
      do: raise("injected #{operation} failure")

    if reason = state.failures[operation], do: {:error, reason}, else: fun.(state.host)
  end
end
