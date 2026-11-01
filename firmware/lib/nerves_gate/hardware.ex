defmodule NervesGate.Hardware do
  @moduledoc """
  The board's plugin-assignable hardware with runtime presence. The board config
  (`:board` `:ports`) is the only description of which resources exist; assignments,
  SDK candidates and the Hardware pages all read this inventory. Plugins own the
  assigned resources and their protocols.
  """
  use GenServer
  alias NervesGate.Observations

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def observe, do: Observations.subscribe_runtime(__MODULE__)

  def inventory do
    GenServer.call(__MODULE__, :inventory)
  catch
    :exit, _ -> []
  end

  @doc "The normalized inventory entry for a resource ID, or nil."
  def fetch(id), do: Enum.find(inventory(), &(&1.id == id))

  def unavailable,
    do: %{available: false, ports: [], error: nil}

  def status do
    NervesGate.Error.read(
      fn ->
        ports = inventory()
        assignments = NervesGate.Plugins.hardware()

        %{
          available: Process.whereis(__MODULE__) != nil,
          ports:
            Enum.map(ports, fn port ->
              setting = assignments.ports[port.id] || %{enabled: false, plugin: nil}

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
    ports = snapshot()
    Observations.put(["hardware"], ports)
    Process.send_after(self(), :poll, 2_000)
    {:ok, ports}
  end

  def handle_call(:inventory, _, ports), do: {:reply, ports, ports}

  def handle_call(:observations, _, ports),
    do: {:reply, [{Observations.table(), ["hardware"]}], ports}

  def handle_info(:poll, previous) do
    ports = snapshot()
    if ports != previous, do: Observations.put(["hardware"], ports)
    Process.send_after(self(), :poll, 2_000)
    {:noreply, ports}
  end

  defp snapshot do
    network =
      case NervesGate.Network.Vintage.snapshot() do
        %{ports: ports} -> ports
        _ -> []
      end

    NervesGate.Hardware.Ports.snapshot(NervesGate.Board.get(:ports) || [], network)
  end
end
