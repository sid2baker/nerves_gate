defmodule NervesGate.Network.Vintage do
  @moduledoc "Firmware adapter. USB is never part of a port-role change. No Ethernet DHCP server or NAT."
  @behaviour NervesGate.Network.Adapter
  alias NervesGate.{Config, Network.LAN}

  @impl true
  def observations(_), do: [{VintageNet, ["interface"]}]

  def configurations(%{"mode" => "shared", "equipment" => address}) do
    [
      {"eth0", port_config(%{method: :disabled})},
      {"eth1", port_config(%{method: :disabled})},
      {"br0", bridge_config(["eth0", "eth1"], ipv4(address))}
    ]
  end

  def configurations(%{"mode" => "ethernet"} = network) do
    [
      {"br0", bridge_config([], %{method: :disabled})},
      {network["internet_port"], port_config(%{method: :dhcp})},
      {Config.equipment_port(network), port_config(ipv4(network["equipment"]))}
    ]
  end

  def configurations(%{"mode" => "unconfigured"}) do
    [
      {"br0", bridge_config([], %{method: :disabled})}
      | Enum.map(["eth0", "eth1"], &{&1, port_config(%{method: :dhcp})})
    ]
  end

  def configurations(%{"mode" => "ports"} = network) do
    [
      {"br0", bridge_config([], %{method: :disabled})}
      | Enum.map(["eth0", "eth1"], fn name ->
          address =
            if network[name] do
              ipv4(network[name]["address"])
            else
              %{method: :disabled}
            end

          {name, port_config(address)}
        end)
    ]
  end

  defp port_config(ipv4), do: %{type: LAN, ipv4: ipv4}

  defp bridge_config(members, ipv4),
    do: %{type: LAN, vintage_net_bridge: %{interfaces: members, stp: true}, ipv4: ipv4}

  defp ipv4(%{"ip_method" => "dhcp"}) do
    %{method: :dhcp}
  end

  defp ipv4(address) do
    config = %{method: :static, address: address["static_ip"], netmask: address["subnet_mask"]}

    config =
      if address["gateway"] do
        Map.put(config, :gateway, address["gateway"])
      else
        config
      end

    if address["nameservers"] do
      Map.put(config, :name_servers, address["nameservers"])
    else
      config
    end
  end

  @impl true
  def apply_config(network, _) do
    configs = configurations(network)
    desired_members = if network["mode"] == "shared", do: ["eth0", "eth1"], else: []
    current_members = get_in(get("br0", "config") || %{}, [:vintage_net_bridge, :interfaces])
    deadline = System.monotonic_time(:millisecond) + 1_500

    # Stop the old bridge membership watcher BEFORE changing port addresses.
    # configure/3 is asynchronous; its completion is a mandatory safety barrier.
    preparation =
      if current_members != desired_members do
        configure("br0", bridge_config([], %{method: :disabled}), deadline)
      else
        :ok
      end

    with :ok <- preparation do
      configure_all(configs, deadline)
    end
  end

  defp configure_all(configs, deadline) do
    Enum.reduce_while(configs, :ok, fn {name, config}, :ok ->
      case configure(name, config, deadline) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp configure(name, config, deadline) do
    with :ok <- settled(name, deadline),
         :ok <- VintageNet.configure(name, config, persist: false) do
      settled(name, deadline)
    end
  end

  defp settled(name, deadline) do
    state = get(name, "state")

    cond do
      state in [nil, :configured] ->
        :ok

      state == :retrying and get(name, "present") != true and name != "br0" ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:busy, name}}

      true ->
        Process.sleep(20)
        settled(name, deadline)
    end
  end

  @impl true
  def snapshot(_) do
    %{
      simulated: false,
      bridge: interface("br0"),
      ports: Enum.map(["eth0", "eth1"], &interface/1),
      usb: interface("usb0")
    }
  end

  defp interface(name) do
    dhcp = get(name, "dhcp_options") || %{}
    ipv4 = get_in(get(name, "config") || %{}, [:ipv4]) || %{}

    %{
      name: name,
      present: get(name, "present") == true,
      link: get(name, "lower_up") == true,
      state: get(name, "state"),
      method: method(get(name, "config")),
      connection: get(name, "connection"),
      addresses: addresses(get(name, "addresses") || []),
      master: master(name),
      gateway: ip_string(List.first(List.wrap(dhcp[:router])) || ipv4[:gateway]),
      nameservers: Enum.map(List.wrap(dhcp[:dns] || ipv4[:name_servers]), &ip_string/1)
    }
  end

  defp ip_string(nil) do
    nil
  end

  defp ip_string(ip) when is_binary(ip) do
    ip
  end

  defp ip_string(ip) do
    ip |> :inet.ntoa() |> to_string()
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
