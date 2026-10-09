defmodule NervesGate.Network.Vintage do
  @moduledoc "Firmware adapter. No DHCP server, NAT or IP address on either bridge member."
  @behaviour NervesGate.Network
  alias NervesGate.Network.LAN

  @doc "The exact configurations used on both firmware targets."
  def configurations(network) do
    ipv4 =
      case network["ip_method"] do
        "dhcp" ->
          %{method: :dhcp}

        "static" ->
          config = %{
            method: :static,
            address: network["static_ip"],
            netmask: network["subnet_mask"]
          }

          if network["gateway"], do: Map.put(config, :gateway, network["gateway"]), else: config
      end

    [
      {"eth0", %{type: LAN, ipv4: %{method: :disabled}}},
      {"eth1", %{type: LAN, ipv4: %{method: :disabled}}},
      {"br0",
       %{type: LAN, vintage_net_bridge: %{interfaces: ["eth0", "eth1"], stp: true}, ipv4: ipv4}}
    ]
  end

  @impl true
  def apply_config(network, _) do
    Enum.reduce_while(configurations(network), :ok, fn {name, config}, :ok ->
      # VintageNet 0.13 does not accept configure calls during :reconfiguring.
      # The manager retries restoration rather than crashing an interface owner.
      result =
        if get(name, "state") == :reconfiguring do
          {:error, {:busy, name}}
        else
          VintageNet.configure(name, config, persist: false)
        end

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @impl true
  def snapshot(_) do
    %{
      simulated: false,
      bridge: %{
        present: get("br0", "present") == true,
        link: get("br0", "lower_up") == true,
        state: get("br0", "state"),
        method: method(get("br0", "config")),
        addresses: addresses(get("br0", "addresses") || [])
      },
      ports:
        Enum.map(["eth0", "eth1"], fn name ->
          %{
            name: name,
            present: get(name, "present") == true,
            link: get(name, "lower_up") == true,
            master: master(name)
          }
        end)
    }
  end

  defp get(name, key), do: VintageNet.get(["interface", name, key])
  defp method(%{ipv4: %{method: method}}), do: to_string(method)
  defp method(_), do: nil

  defp addresses(addresses) do
    for %{family: :inet, address: address, prefix_length: prefix} <- addresses do
      %{address: address |> :inet.ntoa() |> to_string(), prefix_length: prefix}
    end
  end

  defp master(name) do
    case File.read_link("/sys/class/net/#{name}/master") do
      {:ok, path} -> Path.basename(path)
      _ -> nil
    end
  end
end
