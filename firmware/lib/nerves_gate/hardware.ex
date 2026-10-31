defmodule NervesGate.Hardware do
  @moduledoc "Allowlisted Ethernet and bus inventory. Plugins own assigned resources and protocols."
  use GenServer
  alias NervesGate.Observations

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def observe, do: Observations.subscribe_runtime(__MODULE__)

  def inventory do
    GenServer.call(__MODULE__, :inventory)
  catch
    :exit, _ -> []
  end

  def unavailable,
    do: %{available: false, ports: [], error: nil}

  def status do
    NervesGate.Error.read(
      fn ->
        ports = inventory()
        assignments = NervesGate.Plugins.hardware()

        %{
          available:
            Process.whereis(__MODULE__) != nil and
              (ports != [] or NervesGate.Board.get(:ports) != nil),
          ports:
            Enum.map(ports, fn port ->
              setting = assignments.ports[port.name] || %{enabled: false, plugin: nil}

              Map.merge(port, %{
                enabled: setting.enabled,
                assigned_plugin: setting.plugin,
                assignment_error: assignments.error
              })
            end),
          error: nil
        }
      end,
      &unavailable/0
    )
  end

  def init(_) do
    send(self(), :poll)
    {:ok, []}
  end

  def handle_call(:inventory, _, ports), do: {:reply, ports, ports}

  def handle_call(:observations, _, ports),
    do: {:reply, [{Observations.table(), ["hardware"]}], ports}

  def handle_info(:poll, previous) do
    ports =
      case NervesGate.Board.get(:ports) do
        nil -> []
        board_ports -> NervesGate.Hardware.Ports.snapshot(board_ports)
      end

    ethernet =
      case NervesGate.Network.Vintage.snapshot() do
        %{ports: ports} ->
          Enum.map(ports, &Map.merge(&1, %{transport: "ethernet", interface: &1.name}))

        _ ->
          []
      end

    ports = ethernet ++ ports
    if ports != previous, do: Observations.put(["hardware"], ports)
    Process.send_after(self(), :poll, 2_000)
    {:noreply, ports}
  end
end
