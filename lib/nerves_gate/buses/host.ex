defmodule NervesGate.Buses.Host do
  @moduledoc "Bus preview and test adapter. No sockets, serial devices or workstation interfaces."
  use Agent
  alias NervesGate.Buses.Policy

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{ports: initial(), calls: [], delay: 25, failure: nil} end,
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  def execute(operation, name, params, server) do
    settings =
      Agent.get_and_update(server, fn state ->
        {state, %{state | calls: Enum.take([{operation, name, params} | state.calls], 32)}}
      end)

    Process.sleep(settings.delay)

    if settings.failure,
      do: {:error, settings.failure},
      else: perform(operation, name, params, server)
  end

  def snapshot(server), do: Agent.get(server, & &1.ports)
  def simulate(changes, server), do: Agent.update(server, &Map.merge(&1, changes))
  def calls(server), do: Agent.get(server, & &1.calls)

  defp perform(:configure, name, params, server) do
    Agent.update(server, fn state ->
      ports =
        Enum.map(state.ports, &configure_port(&1, name, params))

      %{state | ports: ports}
    end)
  end

  defp perform(:capture, name, _, _) when name in ["can0", "can1"] do
    {:ok,
     %{
       frames: [
         %{
           id: "123",
           extended: false,
           remote: false,
           error: false,
           data: "01020304",
           received_at: System.system_time(:millisecond)
         }
       ]
     }}
  end

  defp perform(:capture, _, _, _), do: {:ok, %{hex: "010302002A399B", bytes: 7}}

  defp perform(:modbus_read, _, params, _),
    do:
      {:ok,
       Map.put(
         params,
         :registers,
         Enum.to_list(params.address..(params.address + params.count - 1))
       )}

  defp configure_port(%{name: name} = port, name, params) do
    Map.merge(
      port,
      Map.put(params, :state, if(params.enabled, do: "error active", else: "stopped"))
    )
  end

  defp configure_port(port, _, _), do: port

  defp initial do
    Enum.map(Policy.ports(), fn
      name when name in ["can0", "can1"] ->
        %{
          name: name,
          transport: "can",
          present: true,
          enabled: false,
          bitrate: 125_000,
          listen_only: true,
          state: "stopped",
          errors: %{tx: 0, rx: 0},
          rx_packets: 0,
          tx_packets: 0
        }

      name ->
        %{
          name: name,
          transport: "rs485",
          present: true,
          enabled: false,
          profile: "9600 8N1 · automatic direction"
        }
    end)
  end
end
