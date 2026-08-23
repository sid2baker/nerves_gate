defmodule NervesGate.Commissioning.Access do
  @moduledoc "Owns temporary local AP and Ethernet commissioning services."

  use GenServer

  alias NervesGate.Commissioning.Alarms
  alias NervesGate.Identity
  alias NervesGate.Internet.Hardware

  defstruct [:adapter, :hardware, active: [], mode: :disabled]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec enable(:commissioning, String.t() | nil, GenServer.server()) ::
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
         Keyword.get(options, :adapter, Application.fetch_env!(:nerves_gate, :internet_adapter)),
       hardware: Keyword.get(options, :hardware, &Hardware.interfaces/0)
     }}
  end

  @impl true
  def handle_call({:enable, mode, uplink}, _from, state) do
    desired = desired_configurations(state.hardware.(), uplink)

    if desired != [] and state.mode == mode and state.active == desired do
      Alarms.unavailable(false)
      {:reply, {:ok, desired}, state}
    else
      Enum.each(state.active, &state.adapter.clear(&1.interface))
      active = configure_available(desired, state.adapter)
      reply_enabled(active, mode, state)
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

  defp desired_configurations(interfaces, uplink) do
    interfaces
    |> commissioning_candidates(uplink)
    |> Enum.with_index()
    |> Enum.map(fn {interface, index} ->
      interface
      |> commissioning_options(index)
      |> Map.put(:interface, interface.name)
    end)
  end

  defp configure_available(configurations, adapter) do
    Enum.filter(configurations, fn configuration ->
      %{interface: interface} = configuration
      options = Map.delete(configuration, :interface)
      adapter.configure_commissioning(interface, options) == :ok
    end)
  end

  defp reply_enabled([], mode, state) do
    Alarms.unavailable(true)
    {:reply, {:error, :no_interface}, %{state | active: [], mode: mode}}
  end

  defp reply_enabled(active, mode, state) do
    Alarms.unavailable(false)
    {:reply, {:ok, active}, %{state | active: active, mode: mode}}
  end

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
