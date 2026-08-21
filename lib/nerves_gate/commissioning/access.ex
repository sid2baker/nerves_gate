defmodule NervesGate.Commissioning.Access do
  @moduledoc "Owns temporary local AP and Ethernet commissioning services."

  use GenServer

  alias NervesGate.Alarm
  alias NervesGate.Alarms
  alias NervesGate.Identity
  alias NervesGate.Network.Hardware

  defstruct [:adapter, :hardware, active: [], mode: :disabled]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec enable(:commissioning | :recovery, String.t() | nil, GenServer.server()) ::
          {:ok, [map()]} | {:error, :no_interface}
  def enable(mode, uplink \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:enable, mode, uplink})
  end

  @spec disable(GenServer.server()) :: :ok
  def disable(server \\ __MODULE__), do: GenServer.call(server, :disable)

  @spec release(String.t(), GenServer.server()) :: :ok
  def release(interface, server \\ __MODULE__), do: GenServer.call(server, {:release, interface})

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(options) do
    {:ok,
     %__MODULE__{
       adapter:
         Keyword.get(options, :adapter, Application.fetch_env!(:nerves_gate, :network_adapter)),
       hardware: Keyword.get(options, :hardware, &Hardware.interfaces/0)
     }}
  end

  @impl true
  def handle_call({:enable, mode, uplink}, _from, state) do
    Enum.each(state.active, &state.adapter.clear(&1.interface))

    interfaces = state.hardware.()
    candidates = commissioning_candidates(interfaces, uplink)

    active =
      candidates
      |> Enum.with_index()
      |> Enum.flat_map(fn {interface, index} ->
        options = commissioning_options(interface, index)

        case state.adapter.configure_commissioning(interface.name, options) do
          :ok -> [Map.put(options, :interface, interface.name)]
          {:error, _reason} -> []
        end
      end)

    case active do
      [] ->
        Alarms.set(Alarm.CommissioningUnavailable)
        {:reply, {:error, :no_interface}, %{state | active: [], mode: mode}}

      available ->
        Alarms.clear(Alarm.CommissioningUnavailable)
        {:reply, {:ok, available}, %{state | active: available, mode: mode}}
    end
  end

  def handle_call(:disable, _from, state) do
    Enum.each(state.active, &state.adapter.clear(&1.interface))
    {:reply, :ok, %{state | active: [], mode: :disabled}}
  end

  def handle_call({:release, interface}, _from, state) do
    active = Enum.reject(state.active, &(&1.interface == interface))
    {:reply, :ok, %{state | active: active}}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{active: state.active, mode: state.mode}, state}
  end

  @spec commissioning_candidates([map()], String.t() | nil) :: [map()]
  def commissioning_candidates(interfaces, uplink) do
    wifi = Enum.filter(interfaces, &(&1.kind == :wifi and &1.name != uplink))

    spare_ethernet =
      interfaces
      |> Enum.filter(&(&1.kind == :ethernet and &1.name != uplink and &1.name != "eth0"))
      |> Enum.sort_by(&ethernet_priority/1)

    wifi ++ spare_ethernet
  end

  defp ethernet_priority(%{name: "eth1"}), do: 0
  defp ethernet_priority(%{name: "eth2"}), do: 1
  defp ethernet_priority(%{name: name}), do: {2, name}

  defp commissioning_options(%{kind: kind}, index) do
    third_octet = 77 + index
    address = "192.168.#{third_octet}.1"

    %{
      kind: kind,
      address: address,
      prefix_length: 24,
      dhcp_start: "192.168.#{third_octet}.10",
      dhcp_end: "192.168.#{third_octet}.200",
      ssid: Identity.get().setup_ssid
    }
  end
end
