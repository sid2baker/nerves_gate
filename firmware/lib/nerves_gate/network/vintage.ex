defmodule NervesGate.Network.Vintage do
  @moduledoc "Firmware adapter. USB is never part of a port-role change. No Ethernet DHCP server or NAT."

  import Bitwise
  alias NervesGate.Config
  alias NervesGate.Network.LAN
  require Logger

  # Listed first in the firmware services: one-time routing setup before Network
  # starts. Tailscale owns its forwarding/NAT rules. Failure must not prevent
  # local/USB web access. Workstation configuration never starts this.
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :prepare_routing, []}}

  def prepare_routing do
    :ok = File.write("/proc/sys/net/ipv4/ip_forward", "0\n")

    {_, 0} =
      System.cmd("iptables", ["-w", "5", "-P", "FORWARD", "DROP"], stderr_to_stdout: true)

    :ok = File.write("/proc/sys/net/ipv4/ip_forward", "1\n")
    :ignore
  rescue
    _exception in [MatchError, ErlangError] ->
      Logger.warning("IPv4 subnet forwarding setup failed; local web access remains available.")
      :ignore
  end

  # Inspect persistence before VintageNet opens the UART. An incompatible saved
  # driver must stop startup, not enter a controller crash/reopen loop. Never
  # migrate or erase settings as a side effect of a firmware source cutover.
  @doc false
  def check_saved_cellular do
    case NervesGate.Cellular.Profile.get() do
      %{interface: name} ->
        case VintageNet.Persistence.call(:load, [name]) do
          {:ok, config} -> NervesGate.Cellular.Profile.check_saved(config)
          {:error, :enoent} -> :ok
          _ -> NervesGate.Cellular.Profile.check_saved(nil)
        end

      nil ->
        :ok
    end
  end

  # DataInit calls this before VintageNet can restore a saved cellular link.
  # A failure stops firmware startup rather than exposing services on that link.
  @doc false
  def prepare_cellular_input do
    for tool <- ["iptables", "ip6tables"],
        rule <- Enum.reverse(cellular_input_rules(tool)) do
      case System.cmd(tool, ["-w", "5", "-C", "INPUT" | rule], stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {_, 1} ->
          {_, 0} =
            System.cmd(tool, ["-w", "5", "-I", "INPUT", "1" | rule], stderr_to_stdout: true)
      end
    end

    :ok
  rescue
    _exception in [MatchError, CaseClauseError, ErlangError] ->
      Logger.error("Cellular INPUT protection failed; refusing to start device services.")
      {:error, :cellular_firewall_unavailable}
  end

  @doc false
  def cellular_input_rules(tool) when tool in ["iptables", "ip6tables"] do
    replies = [
      "-i",
      "wwan+",
      "-m",
      "conntrack",
      "--ctstate",
      "ESTABLISHED,RELATED",
      "-j",
      "ACCEPT"
    ]

    drop = ["-i", "wwan+", "-j", "DROP"]

    # Initial DHCP replies may be broadcast and not match conntrack. ECM uses
    # IPv4 PDP contexts; unsolicited IPv6 (including new connections) is denied.
    dhcp = ["-i", "wwan+", "-p", "udp", "--sport", "67", "--dport", "68", "-j", "ACCEPT"]
    if tool == "iptables", do: [replies, dhcp, drop], else: [replies, drop]
  end

  def observations do
    [{VintageNet, ["interface"]}]
  end

  def load do
    with {:ok, configs} <- saved_configurations(),
         {:ok, network} <- from_configurations(configs) do
      {:ok, NervesGate.Config.from_network(network)}
    end
  end

  def save(network) do
    with {:ok, configs} <- all_configurations(network) do
      Enum.reduce_while(configs, :ok, &save_interface/2)
    end
  end

  defp save_interface({name, config}, :ok) do
    case VintageNet.Persistence.call(:save, [name, config.type.normalize(config)]) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  def configurations(network) do
    roles = Config.ports(network)

    Enum.map(configs(network), fn
      {"br0", config} ->
        config = Map.put(config, :nerves_gate_mode, network["mode"])

        config =
          if network["internet"],
            do: Map.put(config, :nerves_gate_internet, network["internet"]),
            else: config

        {"br0", config}

      {name, config} ->
        {name, Map.put(config, :nerves_gate_role, get_in(roles, [name, "role"]))}
    end)
  end

  @doc "Reconstruct the form from VintageNet settings; only mode and port-role labels are extra metadata."
  def from_configurations(configs) when map_size(configs) == 0,
    do: {:ok, Config.defaults()["network"]}

  def from_configurations(%{"br0" => %{vintage_net_bridge: %{interfaces: [_ | _]}}}),
    do:
      {:error, "Only independent Ethernet interfaces are supported; saved state was not changed."}

  def from_configurations(configs) do
    ports = Map.new(["eth0", "eth1"], &{&1, saved_port(configs[&1])})

    network =
      case get_in(configs, ["br0", :nerves_gate_mode]) do
        "ports" ->
          Map.put(ports, "mode", "ports")

        "unconfigured" ->
          %{"mode" => "unconfigured"}

        _ ->
          nil
      end

    internet = get_in(configs, ["br0", :nerves_gate_internet])
    network = if network && internet, do: Map.put(network, "internet", internet), else: network
    Config.validate_network(network)
  end

  defp saved_port(%{nerves_gate_role: "application", ipv4: %{method: :disabled}}),
    do: %{"role" => "application", "address" => nil}

  defp saved_port(%{nerves_gate_role: "internet"} = config),
    do: %{"role" => "internet", "address" => saved_address(config)}

  defp saved_port(%{
         nerves_gate_role: nil,
         nerves_gate_disabled: true,
         ipv4: %{method: :disabled}
       }),
       do: nil

  defp saved_port(%{nerves_gate_role: role}), do: %{"role" => role}
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

  defp configs(%{"mode" => "unconfigured"}) do
    [
      {"br0", metadata_config()}
      | Enum.map(["eth0", "eth1"], &{&1, port_config(%{method: :dhcp})})
    ]
  end

  defp configs(%{"mode" => "ports"} = network) do
    [
      {"br0", metadata_config()}
      | Enum.map(["eth0", "eth1"], fn name ->
          address =
            if get_in(network, [name, "address"]) do
              ipv4(network[name]["address"])
            else
              %{method: :disabled}
            end

          {name, Map.put(port_config(address), :nerves_gate_disabled, is_nil(network[name]))}
        end)
    ]
  end

  defp port_config(ipv4), do: %{type: LAN, ipv4: ipv4}

  defp metadata_config,
    do: %{type: LAN, vintage_net_bridge: %{interfaces: [], stp: true}, ipv4: %{method: :disabled}}

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

  @doc false
  def apply_local(name, address) when name in ["eth0", "eth1"] do
    ipv4 = if address, do: ipv4(address), else: %{method: :disabled}
    config = port_config(ipv4) |> Map.put(:nerves_gate_role, "application")
    configure(name, config, System.monotonic_time(:millisecond) + 8_000, true)
  end

  def apply_config(network) do
    apply_network(network, false)
  end

  def restore(network) do
    apply_network(network, true)
  end

  defp apply_network(network, force) do
    with {:ok, configs} <- all_configurations(network) do
      configure_all(configs, System.monotonic_time(:millisecond) + 8_000, force)
    end
  end

  defp all_configurations(network) do
    with {:ok, cellular} <- NervesGate.Cellular.Profile.configurations(network),
         do: {:ok, configurations(network) ++ cellular}
  end

  defp configure_all(configs, deadline, force) do
    Enum.reduce_while(configs, :ok, fn {name, config}, :ok ->
      case configure(name, config, deadline, force) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Modem registration can take minutes. Accept the standard technology's
  # configuration without making carrier registration a LAN trial prerequisite.
  defp configure(name, config, _deadline, _force) when name not in ["eth0", "eth1", "br0"],
    do: VintageNet.configure(name, config, persist: false)

  defp configure(name, config, deadline, force) do
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

  def snapshot do
    if :ets.whereis(VintageNet) != :undefined do
      interfaces()
    end
  end

  defp interfaces do
    %{
      simulated: false,
      bridge: interface("br0"),
      ports: Enum.map(["eth0", "eth1"], &interface/1),
      usb: interface("usb0"),
      management: management_interfaces(),
      cellular_supported: NervesGate.Cellular.Profile.get() != nil,
      cellular: cellular_interface()
    }
  end

  defp management_interfaces do
    Application.get_env(:vintage_net, :config, [])
    |> Enum.map(fn {name, _} -> name end)
    |> Enum.reject(&(&1 in ["eth0", "eth1", "br0", "usb0"]))
    |> Enum.map(&interface/1)
  end

  defp cellular_interface do
    if profile = NervesGate.Cellular.Profile.get() do
      config = get(profile.interface, "config") || %{}

      options =
        config[:vintage_net_ecm] || config[:vintage_net_qmi] || config[:vintage_net_mobile] || %{}

      provider = List.first(options[:service_providers] || []) || %{}

      interface(profile.interface)
      |> Map.merge(%{configured: config[:type] == profile.config.type, apn: provider[:apn]})
    end
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
