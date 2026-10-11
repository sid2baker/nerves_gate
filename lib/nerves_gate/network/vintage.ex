defmodule NervesGate.Network.Vintage do
  @moduledoc "Firmware adapter. USB is never part of a port-role change. No Ethernet DHCP server or NAT."
  @behaviour NervesGate.Network.Adapter
  import Bitwise
  alias NervesGate.{Config, Network.LAN}

  @impl true
  def observations(_), do: [{VintageNet, ["interface"]}]

  @impl true
  def load(_) do
    with {:ok, configs} <- saved_configurations(),
         {:ok, network} <- from_configurations(configs),
         do: {:ok, Config.from_network(network)}
  end

  @impl true
  def save(network, _) do
    # configure/3 skips identical configurations and logs persistence failures.
    # Save explicitly so confirming a temporary configuration really persists it
    # and reports errors. These are VintageNet's files, not an application journal.
    Enum.reduce_while(configurations(network), :ok, fn {name, config}, :ok ->
      case VintageNet.Persistence.call(:save, [name, LAN.normalize(config)]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def configurations(network) do
    roles = Config.ports(network)

    Enum.map(configs(network), fn
      {"br0", config} -> {"br0", Map.put(config, :nerves_gate_mode, network["mode"])}
      {name, config} -> {name, Map.put(config, :nerves_gate_role, get_in(roles, [name, "role"]))}
    end)
  end

  @doc "Reconstruct the form from VintageNet settings; only mode and port-role labels are extra metadata."
  def from_configurations(configs) when map_size(configs) == 0,
    do: {:ok, Config.defaults()["network"]}

  def from_configurations(configs) do
    ports = Map.new(["eth0", "eth1"], &{&1, saved_port(configs[&1])})

    network =
      case get_in(configs, ["br0", :nerves_gate_mode]) do
        "shared" ->
          %{"mode" => "shared", "equipment" => saved_address(configs["br0"])}

        "ports" ->
          Map.put(ports, "mode", "ports")

        "unconfigured" ->
          %{"mode" => "unconfigured"}

        _ ->
          nil
      end

    Config.validate_network(network)
  end

  defp saved_port(%{nerves_gate_role: role} = config) when role in ["internet", "equipment"],
    do: %{"role" => role, "address" => saved_address(config)}

  defp saved_port(_), do: nil

  defp saved_address(%{ipv4: %{method: :dhcp}}), do: Config.address_defaults()

  defp saved_address(%{ipv4: %{method: :static, prefix_length: prefix} = ipv4}) do
    <<a, b, c, d>> = <<0xFFFFFFFF <<< (32 - prefix)::32>>

    address = %{
      "ip_method" => "static",
      "static_ip" => ip_string(ipv4.address),
      "subnet_mask" => ip_string({a, b, c, d}),
      "gateway" => ip_string(ipv4[:gateway])
    }

    if ipv4[:name_servers] in [nil, []],
      do: address,
      else: Map.put(address, "nameservers", Enum.map(ipv4.name_servers, &ip_string/1))
  end

  defp saved_address(_), do: nil

  defp saved_configurations do
    Enum.reduce_while(["eth0", "eth1", "br0"], {:ok, %{}}, fn name, {:ok, configs} ->
      case VintageNet.Persistence.call(:load, [name]) do
        {:ok, config} -> {:cont, {:ok, Map.put(configs, name, config)}}
        {:error, :enoent} -> {:cont, {:ok, configs}}
        error -> {:halt, error}
      end
    end)
  end

  defp configs(%{"mode" => "shared", "equipment" => address}) do
    [
      {"eth0", port_config(%{method: :disabled})},
      {"eth1", port_config(%{method: :disabled})},
      {"br0", bridge_config(["eth0", "eth1"], ipv4(address))}
    ]
  end

  defp configs(%{"mode" => "unconfigured"}) do
    [
      {"br0", bridge_config([], %{method: :disabled})}
      | Enum.map(["eth0", "eth1"], &{&1, port_config(%{method: :dhcp})})
    ]
  end

  defp configs(%{"mode" => "ports"} = network) do
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
  def apply_config(network, _), do: apply_network(network, false)

  @impl true
  def restore(network, _), do: apply_network(network, true)

  defp apply_network(network, force) do
    configs = configurations(network)

    desired_members =
      if network["mode"] == "shared" do
        ["eth0", "eth1"]
      else
        []
      end

    current_members = get_in(get("br0", "config") || %{}, [:vintage_net_bridge, :interfaces])
    deadline = System.monotonic_time(:millisecond) + 1500

    preparation =
      if current_members != desired_members do
        configure("br0", bridge_config([], %{method: :disabled}), deadline)
      else
        :ok
      end

    with :ok <- preparation do
      configure_all(configs, deadline, force)
    end
  end

  defp configure_all(configs, deadline, force) do
    Enum.reduce_while(configs, :ok, fn {name, config}, :ok ->
      case configure(name, config, deadline, force) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp configure(name, config, deadline, force \\ false) do
    with :ok <- settled(name, deadline, true),
         :ok <- reset_if_needed(name, config, deadline, force),
         :ok <- VintageNet.configure(name, config, persist: false) do
      settled(name, deadline, false)
    end
  end

  defp reset_if_needed(name, config, deadline, force) do
    # configure/3 publishes its config BEFORE sending it to the interface process.
    # A killed caller can leave that property ahead of the hardware. On restoration,
    # bypass its identical-config shortcut through the public deconfigure API.
    if force and get(name, "config") == LAN.normalize(config) do
      with :ok <- VintageNet.deconfigure(name, persist: false),
           do: settled(name, deadline, false)
    else
      :ok
    end
  end

  defp settled(name, deadline, allow_missing) do
    state = get(name, "state")

    cond do
      state == :configured ->
        synchronize(name)

      allow_missing and state == nil ->
        :ok

      state == :retrying and get(name, "present") != true and name != "br0" ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:busy, name}}

      true ->
        Process.sleep(20)
        settled(name, deadline, allow_missing)
    end
  end

  defp synchronize(name) do
    # init publishes :configured before its internal configure event. Synchronize
    # with the interface mailbox, not only that briefly stale property.
    if name == "br0" or get(name, "present") == true,
      do: VintageNet.Interface.wait_until_configured(name),
      else: :ok
  end

  @impl true
  def snapshot(_) do
    if :ets.whereis(VintageNet) != :undefined, do: interfaces()
  end

  defp interfaces do
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
