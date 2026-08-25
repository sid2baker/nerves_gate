defmodule NervesGate.Commissioning.Access do
  @moduledoc "Pure commissioning-interface selection and idempotent runtime operations."

  alias NervesGate.Identity

  @spec reconcile(module(), [map()], [map()], String.t() | nil) ::
          {:ok, [map()]} | {:error, :no_interface}
  def reconcile(adapter, interfaces, active, uplink) do
    desired = desired_configurations(interfaces, uplink)

    if desired != [] and active == desired do
      {:ok, desired}
    else
      clear(adapter, active)

      case configure_available(desired, adapter) do
        [] -> {:error, :no_interface}
        configured -> {:ok, configured}
      end
    end
  end

  @spec clear_all(module(), [map()], [map()], String.t() | nil) :: :ok
  def clear_all(adapter, interfaces, active, uplink) do
    candidates =
      interfaces
      |> commissioning_candidates(uplink)
      |> Enum.map(&%{interface: &1.name})

    clear(adapter, Enum.uniq_by(active ++ candidates, & &1.interface))
  end

  @spec clear(module(), [map()]) :: :ok
  def clear(adapter, active) do
    Enum.each(active, &adapter.clear(&1.interface))
    :ok
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
