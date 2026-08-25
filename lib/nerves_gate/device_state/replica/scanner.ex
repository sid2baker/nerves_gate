defmodule NervesGate.DeviceState.Replica.Scanner do
  @moduledoc false

  use GenServer

  alias NervesGate.DeviceState.Replica.Supervisor, as: ReplicaSupervisor

  @interval 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl true
  def init(options) do
    scan = Keyword.get(options, :scan, &ReplicaSupervisor.sync_connected/0)
    scan.()
    schedule_scan()
    {:ok, scan}
  end

  @impl true
  def handle_info(:scan, scan) do
    scan.()
    schedule_scan()
    {:noreply, scan}
  end

  defp schedule_scan, do: Process.send_after(self(), :scan, @interval)
end
