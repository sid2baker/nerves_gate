defmodule NervesGate.TestNetwork do
  @moduledoc "Real networks for the owned bench. The session namespace owns their lifetime."

  @ports %{lan1: "ng-lan1", lan2: "ng-lan2"}
  @networks %{internet: "ng-internet", equipment: "ng-equipment"}

  def baseline, do: connections(:lan1)

  def connections(port) when port in [:lan1, :lan2, :off] do
    Map.new(@ports, fn {name, _} ->
      {name, if(name == port, do: :internet, else: :equipment)}
    end)
  end

  def setup(dir) do
    isolated!()

    for {network, bridge} <- @networks do
      mac = if network == :internet, do: "02:00:00:00:02:02", else: "02:00:00:00:03:02"
      command!("ip", ["link", "add", bridge, "address", mac, "type", "bridge"])
      command!("ip", ["link", "set", bridge, "up"])
    end

    command!("ip", ~w"addr add 10.0.2.2/24 dev ng-internet")
    command!("ip", ~w"addr add 10.0.3.2/24 dev ng-equipment")

    for tap <- Map.values(@ports) do
      command!("ip", ["tuntap", "add", "dev", tap, "mode", "tap"])
      command!("ip", ["link", "set", tap, "up"])
    end

    # Default-deny forwarding also covers IPv6, management and equipment. Never
    # accept established traffic generically: a moved cable must lose its old path.
    rules = Path.join(dir, "topology.nft")

    File.write!(rules, """
    table inet ng_topology {
      chain input {
        type filter hook input priority 0; policy accept;
        iifname "lo" accept
        iifname "ng-internet" udp dport { 53, 67 } accept
        iifname "ng-internet" tcp dport 53 accept
        iifname { "ng-internet", "ng-equipment" } ip protocol icmp accept
        iifname { "ng-internet", "ng-equipment" } drop
        iifname != "ng-internet" ip daddr 10.0.2.2 drop
      }
      chain forward {
        type filter hook forward priority 0; policy drop;
        iifname "ng-internet" oifname "ng-internet" accept
        iifname "ng-equipment" oifname "ng-equipment" accept
        iifname "ng-internet" oifname "ng-uplink" ip saddr 10.0.2.0/24 accept
        iifname "ng-uplink" oifname "ng-internet" ip daddr 10.0.2.0/24 ct state established,related accept
        counter drop
      }
      chain nat {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "ng-uplink" ip saddr 10.0.2.0/24 masquerade
      }
    }
    """)

    command!("nft", ["-f", rules])
    File.write!("/proc/sys/net/ipv4/ip_forward", "1\n")
    connect(:lan1)
  end

  def reset do
    connect(:lan1)
    for port <- Map.keys(@ports), do: set_cable(port, true)
  end

  def cables do
    Map.new(@ports, fn {port, tap} -> {port, "UP" in interface(tap)["flags"]} end)
  end

  def set_cable(port, up) when port in [:lan1, :lan2] and is_boolean(up) do
    command!("ip", ["link", "set", Map.fetch!(@ports, port), if(up, do: "up", else: "down")])
    ^up = Map.fetch!(cables(), port)
    :ok
  end

  def router_args do
    [
      # This rootless test namespace disallows setgroups. Debug foreground mode
      # skips dnsmasq's privilege switching; it does not grant host privileges.
      "--no-daemon",
      "--conf-file=/dev/null",
      "--bind-interfaces",
      "--interface=ng-internet",
      "--except-interface=lo",
      "--no-resolv",
      "--no-hosts",
      "--host-record=router.test,10.0.2.2",
      "--server=192.0.2.3",
      "--dhcp-authoritative",
      "--dhcp-range=10.0.2.15,10.0.2.200,255.255.255.0,1h",
      "--dhcp-option=option:router,10.0.2.2",
      "--dhcp-option=option:dns-server,10.0.2.2",
      "--leasefile-ro",
      "--log-facility=-"
    ]
  end

  def router_ready? do
    isolated!()

    :inet_res.lookup(
      ~c"router.test",
      :in,
      :a,
      [nameservers: [{{10, 0, 2, 2}, 53}], retry: 1, timeout: 250],
      500
    ) == [{10, 0, 2, 2}]
  end

  # Only cable attachment changes. Guest NICs, MAC addresses and settings stay put.
  def connect(port) when port in [:lan1, :lan2, :off] do
    isolated!()

    # Detach both before attaching either: never briefly join the two networks.
    for tap <- Map.values(@ports), do: command!("ip", ["link", "set", tap, "nomaster"])

    for {name, tap} <- @ports do
      network = if name == port, do: :internet, else: :equipment
      command!("ip", ["link", "set", tap, "master", Map.fetch!(@networks, network)])
    end

    expected = connections(port)
    ^expected = snapshot()
    expected
  end

  def snapshot do
    isolated!()

    Map.new(@ports, fn {port, tap} -> {port, network(tap)} end)
  end

  defp network(tap) do
    # Netlink observes this network namespace; an inherited /sys mount may not.
    case interface(tap)["master"] do
      nil ->
        :disconnected

      bridge ->
        {network, ^bridge} = Enum.find(@networks, fn {_, name} -> name == bridge end)
        network
    end
  end

  defp interface(tap) do
    [link] = command!("ip", ["-j", "link", "show", "dev", tap]) |> Jason.decode!()
    link
  end

  def forwarding_drops do
    rules = command!("nft", ~w"-j list chain inet ng_topology forward") |> Jason.decode!()

    for %{"rule" => %{"expr" => expressions}} <- rules["nftables"],
        %{"counter" => %{"packets" => packets}} <- expressions,
        reduce: 0 do
      count -> count + packets
    end
  end

  defp command!(executable, args) do
    isolated!()

    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "Bench #{executable} failed (#{status}): #{output}"
    end
  end

  defp isolated! do
    if File.read_link!("/proc/self/ns/net") == System.fetch_env!("NERVES_GATE_HOST_NETNS"),
      do: raise("Refusing to configure bench networks in the workstation namespace")
  end
end
