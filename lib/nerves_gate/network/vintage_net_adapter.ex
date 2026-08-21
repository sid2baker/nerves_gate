defmodule NervesGate.Network.VintageNetAdapter do
  @moduledoc "VintageNet implementation used on Nerves targets."

  @behaviour NervesGate.Network.Adapter

  alias NervesGate.Network.Config

  @impl true
  def configure_uplink(%Config{} = config) do
    vintage_net().configure(config.interface, vintage_config(config), persist: false)
  catch
    kind, _reason -> {:error, {:vintage_net, kind}}
  end

  @impl true
  def clear(interface) do
    vintage_net().deconfigure(interface, persist: false)
  catch
    kind, _reason -> {:error, {:vintage_net, kind}}
  end

  @impl true
  def configure_commissioning(interface, %{kind: kind} = options) do
    base = %{
      ipv4: %{
        method: :static,
        address: options.address,
        prefix_length: options.prefix_length
      },
      dhcpd: %{
        start: options.dhcp_start,
        end: options.dhcp_end,
        options: %{
          dns: [options.address],
          router: [options.address],
          subnet: "255.255.255.0"
        }
      }
    }

    config =
      case kind do
        :ethernet -> Map.put(base, :type, VintageNetEthernet)
        :wifi -> Map.merge(base, wifi_ap(options.ssid))
      end

    vintage_net().configure(interface, config, persist: false)
  catch
    kind, _reason -> {:error, {:vintage_net, kind}}
  end

  @impl true
  def snapshot(interface) do
    case vintage_net().get(["interface", interface]) do
      nil -> %{}
      value when is_map(value) -> value
      _value -> %{}
    end
  catch
    _kind, _reason -> %{}
  end

  defp vintage_net, do: Module.concat(["VintageNet"])

  defp vintage_config(%Config{kind: :ethernet} = config) do
    %{type: VintageNetEthernet, ipv4: ipv4(config)}
  end

  defp vintage_config(%Config{kind: :wifi} = config) do
    %{
      type: VintageNetWiFi,
      ipv4: ipv4(config),
      vintage_net_wifi: %{
        networks: [
          %{
            ssid: config.ssid,
            key_mgmt: key_management(config),
            psk: config.password,
            scan_ssid: if(config.hidden, do: 1, else: 0)
          }
        ]
      }
    }
  end

  defp ipv4(%Config{method: :dhcp}), do: %{method: :dhcp}

  defp ipv4(config) do
    %{
      method: :static,
      address: config.address,
      prefix_length: config.prefix_length,
      gateway: config.gateway,
      name_servers: Enum.reject([config.dns_primary, config.dns_secondary], &is_nil/1),
      domain: config.search_domain
    }
  end

  defp key_management(%Config{security: :open}), do: :none
  defp key_management(_config), do: :wpa_psk

  defp wifi_ap(ssid) do
    %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [%{ssid: ssid, mode: :ap, key_mgmt: :none}]
      }
    }
  end
end
