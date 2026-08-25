defmodule NervesGate.Internet.Adapter do
  @moduledoc "Boundary for target network configuration and host simulations."

  alias NervesGate.Internet.Config

  @callback configure_uplink(Config.t()) :: :ok | {:error, term()}
  @callback clear(String.t()) :: :ok | {:error, term()}
  @callback configure_commissioning(String.t(), map()) :: :ok | {:error, term()}
  @callback snapshot(String.t()) :: map()
end

defmodule NervesGate.Internet.Hardware do
  @moduledoc "Discovers local interfaces without assuming Wi-Fi is present."

  @spec interfaces() :: [map()]
  def interfaces do
    case File.ls("/sys/class/net") do
      {:ok, names} ->
        names
        |> Enum.reject(&(&1 in ["lo", "tailscale0"]))
        |> Enum.sort()
        |> Enum.map(&describe/1)

      {:error, _reason} ->
        []
    end
  end

  @spec describe(String.t()) :: map()
  def describe(name) do
    %{
      name: name,
      kind: if(File.dir?("/sys/class/net/#{name}/wireless"), do: :wifi, else: :ethernet),
      carrier: read_carrier(name),
      mac: read_trimmed("/sys/class/net/#{name}/address")
    }
  end

  defp read_carrier(name) do
    case read_trimmed("/sys/class/net/#{name}/carrier") do
      "1" -> true
      "0" -> false
      _unknown -> nil
    end
  end

  defp read_trimmed(path) do
    case File.read(path) do
      {:ok, value} -> String.trim(value)
      {:error, _reason} -> nil
    end
  end
end

defmodule NervesGate.Internet.HostAdapter do
  @moduledoc false
  @behaviour NervesGate.Internet.Adapter

  @impl true
  def configure_uplink(_config), do: :ok

  @impl true
  def clear(_interface), do: :ok

  @impl true
  def configure_commissioning(_interface, _options), do: :ok

  @impl true
  def snapshot(_interface), do: %{}
end

defmodule NervesGate.Internet.VintageNetAdapter do
  @moduledoc "VintageNet implementation used on Nerves targets."

  @behaviour NervesGate.Internet.Adapter

  alias NervesGate.Internet.Config

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
