defmodule NervesGate.TestInternetAdapter do
  @moduledoc false
  @behaviour NervesGate.Internet.Adapter

  def start_link do
    Agent.start_link(fn -> %{calls: [], current: nil} end, name: __MODULE__)
  end

  def reset do
    if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
    start_link()
  end

  def state, do: Agent.get(__MODULE__, & &1)

  @impl true
  def configure_uplink(config), do: record({:uplink, config}, config)

  @impl true
  def clear(interface), do: record({:clear, interface}, nil)

  @impl true
  def configure_commissioning(interface, options),
    do: record({:commissioning, interface, options}, options)

  @impl true
  def snapshot(_interface), do: %{}

  defp record(call, current) do
    Agent.update(__MODULE__, fn state ->
      %{state | calls: state.calls ++ [call], current: current}
    end)
  end
end
