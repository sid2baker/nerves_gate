# Invoked ONLY by scripts/test_bridge.sh, inside its empty network/mount namespaces.
if File.read_link!("/proc/self/ns/net") == System.fetch_env!("NERVES_GATE_HOST_NETNS"),
  do: raise("Refusing host network")

ExUnit.start()
Application.ensure_all_started(:logger)
Application.ensure_all_started(:phoenix_pubsub)
Application.ensure_all_started(:jason)
{:ok, _} = Application.ensure_all_started(:jido)
Application.load(:vintage_net)

for {key, value} <- [
      persistence: VintageNet.Persistence.FlatFile,
      persistence_dir: "/run/saved_network",
      persistence_secret: "integration-test",
      config: [],
      tmpdir: "/run/vintage_net",
      resolvconf: "/run/resolv.conf",
      path: System.fetch_env!("PATH")
    ] do
  Application.put_env(:vintage_net, key, value)
end

{:ok, _} = Application.ensure_all_started(:vintage_net)

ExUnit.configure(timeout: 240_000)

defmodule NervesGate.BridgeIntegrationTest do
  use ExUnit.Case
  alias NervesGate.{Config, Network}
  alias NervesGate.Network.Vintage

  test "real bridge: absent port, hotplug, both directions, DHCP, static and rollback" do
    start_supervised!({Phoenix.PubSub, name: NervesGate.PubSub})
    start_supervised!({Registry, keys: :unique, name: NervesGate.Registry})
    start_supervised!({PropertyTable, name: NervesGate.Properties})
    start_supervised!({Jido, name: NervesGate.Jido})
    # LAN isolation test: explicit in-memory empty route authority, never a host VPN.
    start_supervised!(NervesGate.Remote.Host)

    start_supervised!(
      {NervesGate.Remote, adapter: {NervesGate.Remote.Host, NervesGate.Remote.Host}}
    )

    static = %{
      "ip_method" => "static",
      "static_ip" => "10.45.0.10",
      "subnet_mask" => "255.255.255.0",
      "gateway" => nil
    }

    static = %{"mode" => "shared", "equipment" => static}

    server =
      start_supervised!(
        {NervesGate.Network, adapter: {NervesGate.Network.Vintage, nil}, poll_ms: 100}
      )

    # Fresh boot discovers the router, without USB or a saved role assignment.
    wait(fn -> hd(Vintage.snapshot(nil).ports).addresses != [] end)
    snapshot = Vintage.snapshot(nil)
    assert NervesGate.Network.Discovery.internet_port(snapshot.ports) == "eth0"
    assert Enum.all?(snapshot.ports, &is_nil(&1.master))
    assert snapshot.bridge.addresses == []
    detected_ip = hd(hd(snapshot.ports).addresses).address
    port = start_web()
    assert settings_http?("peer0", port, detected_ip)
    IO.puts("PASS fresh DHCP detection and setup over Ethernet before USB exists")

    cmd("ip", ~w(link add usb0 type veth peer name setup0))
    cmd("ip", ~w(netns add setup))
    cmd("ip", ~w(link set setup0 netns setup))
    cmd("ip", ~w(-n setup link set lo up))
    cmd("ip", ~w(-n setup link set setup0 up))
    cmd("ip", ~w(-n setup addr add 172.30.0.2/30 dev setup0))

    :ok =
      VintageNet.configure(
        "usb0",
        %{
          type: VintageNetEthernet,
          ipv4: %{method: :static, address: "172.30.0.1", netmask: "255.255.255.252"}
        },
        persist: false
      )

    access = %{local: "172.30.0.1", peer: {172, 30, 0, 2}}
    wait(fn -> Network.Access.usb?(Vintage.snapshot(nil), access) end)
    assert settings_http?("setup", port)

    partial = %{
      "mode" => "ports",
      "eth0" => %{"role" => "internet", "address" => Config.address_defaults()},
      "eth1" => nil
    }

    assert {:ok, _} = Network.propose(partial, server, access)
    wait(fn -> Network.status(server).trial == nil end)
    assert Network.status(server).config["setup_completed"]
    assert Network.status(server).config["network"] == partial
    assert {:ok, saved} = Vintage.load(nil)
    assert saved["network"] == partial
    assert settings_http?("setup", port)
    IO.puts("PASS first USB setup auto-saves Internet-only settings; equipment can wait")

    assert {:ok, trial} = Network.propose(static, server, access)
    refute Network.status(server).trial.auto_save
    wait(fn -> Network.status(server).ready end)
    assert :ok = Network.confirm(trial, server)
    wait(fn -> ping?("10.45.0.2") end)
    cmd("ip", ~w(netns exec peer0 ping -c 1 -W 1 10.45.0.10))
    IO.puts("PASS single-port gateway-to-peer and peer-to-gateway")

    cmd("ip", ~w(link add eth1 type veth peer name lan1))
    cmd("ip", ~w(link set lan1 netns peer1))
    cmd("ip", ~w(-n peer1 link set lo up))
    cmd("ip", ~w(-n peer1 link set lan1 up))
    cmd("ip", ~w(-n peer1 addr add 10.45.0.3/24 dev lan1))
    wait(fn -> ping?("10.45.0.3") end)
    cmd("ip", ~w(netns exec peer0 ping -c 1 -W 1 10.45.0.3))
    cmd("ip", ~w(netns exec peer1 ping -c 1 -W 1 10.45.0.2))
    IO.puts("PASS hotplug second port and transparent bidirectional bridging")

    cmd("ip", ~w(link set eth0 down))
    assert ping?("10.45.0.3")
    cmd("ip", ~w(link set eth0 up))

    for name <- ["eth0", "eth1"] do
      {addresses, 0} = System.cmd("ip", ["-j", "addr", "show", "dev", name])
      assert [%{"addr_info" => []}] = Jason.decode!(addresses)
    end

    IO.puts("PASS either cable independently; no IP addresses on members")
    bridge_index = File.read!("/sys/class/net/br0/ifindex")

    dhcp = %{"mode" => "shared", "equipment" => Config.address_defaults()}
    assert {:ok, trial} = Network.propose(dhcp, server)
    wait(fn -> Network.status(server).ready end)
    assert :ok = Network.confirm(trial, server)
    wait(fn -> Vintage.snapshot(nil).bridge.addresses != [] end)
    dhcp_ip = hd(Vintage.snapshot(nil).bridge.addresses).address
    assert dhcp_ip in Enum.map(50..55, &"10.45.0.#{&1}")
    IO.puts("PASS real DHCP client on br0: #{dhcp_ip}")

    assert {:ok, trial} = Network.propose(static, server)
    wait(fn -> Network.status(server).ready end)
    assert :ok = Network.confirm(trial, server)
    wait(fn -> ping?("10.45.0.2") end)
    assert ping?("10.45.0.3")
    IO.puts("PASS live DHCP-to-static reconfiguration")

    # Accelerate timeout only; application uses 60 seconds in production.
    :sys.replace_state(Network.runtime(server), &%{&1 | trial_ms: 1_000})

    assert {:ok, _} =
             Network.propose(put_in(static, ["equipment", "static_ip"], "10.45.0.20"), server)

    wait(fn ->
      status = Network.status(server)
      status.trial == nil and not status.recovering
    end)

    wait(fn -> Network.ready?(Vintage.snapshot(nil), static) end)
    wait(fn -> ping?("10.45.0.3") end)
    assert {:ok, saved} = NervesGate.Network.Vintage.load(nil)
    assert saved["network"] == static
    IO.puts("PASS timed rollback and durable confirmed configuration")

    assert {:ok, _} =
             Network.propose(put_in(static, ["equipment", "static_ip"], "10.45.0.30"), server)

    stop_supervised!(Network)

    # Reproduce a killed configure caller: its desired property may already be
    # updated even though the interface still has the trial's address.
    saved_bridge = Map.new(Vintage.configurations(static))["br0"]

    PropertyTable.put(
      VintageNet,
      ["interface", "br0", "config"],
      Network.LAN.normalize(saved_bridge)
    )

    server =
      start_supervised!(
        {NervesGate.Network, adapter: {NervesGate.Network.Vintage, nil}, poll_ms: 100}
      )

    assert {:ok, saved} = Vintage.load(nil)
    assert saved["network"] == static
    assert Network.status(server).config == saved
    wait(fn -> Network.ready?(Vintage.snapshot(nil), static) end)
    assert Network.status(server).trial == nil
    assert File.read!("/sys/class/net/br0/ifindex") == bridge_index
    # Forced restoration may restart STP forwarding even though br0 survives.
    wait(fn -> ping?("10.45.0.2") end)
    IO.puts("PASS manager restart restores confirmed IP without recreating the bridge")

    # The same endpoint accepts both LAN peers after a topology change.
    assert settings_http?("peer0", port, "10.45.0.10")
    assert settings_http?("peer1", port, "10.45.0.10")
    assert settings_http?("setup", port)
    IO.puts("PASS settings page over both Ethernet ports and independent USB")

    separated = %{
      "mode" => "ports",
      "eth0" => %{"role" => "internet", "address" => NervesGate.Config.address_defaults()},
      "eth1" => %{
        "role" => "equipment",
        "address" => %{static["equipment"] | "static_ip" => "10.46.0.10"}
      }
    }

    cmd("ip", ~w(-n peer1 addr flush dev lan1))
    cmd("ip", ~w(-n peer1 addr add 10.46.0.3/24 dev lan1))
    :sys.replace_state(Network.runtime(server), &%{&1 | trial_ms: 60_000})
    assert {:ok, trial} = Network.propose(separated, server)
    wait(fn -> Network.status(server).ready end)
    assert :ok = Network.confirm(trial, server)
    wait(fn -> hd(Vintage.snapshot(nil).ports).addresses != [] end)
    assert Enum.all?(Vintage.snapshot(nil).ports, &is_nil(&1.master))
    assert Vintage.snapshot(nil).bridge.addresses == []
    assert ping?("10.45.0.2")
    assert ping?("10.46.0.3")
    assert settings_http?("setup", port)
    internet_ip = hd(hd(Vintage.snapshot(nil).ports).addresses).address
    assert settings_http?("peer0", port, internet_ip)
    assert settings_http?("peer1", port, "10.46.0.10")
    IO.puts("PASS settings page on separate Internet, equipment and USB interfaces")
    # Prove L2 separation using matching peer subnets: traffic cannot cross.
    cmd("ip", ~w(-n peer1 addr add 10.45.0.3/24 dev lan1))

    {_, code} =
      System.cmd("ip", ~w(netns exec peer1 ping -c 1 -W 1 10.45.0.2), stderr_to_stdout: true)

    assert code != 0
    cmd("ip", ~w(-n peer1 addr del 10.45.0.3/24 dev lan1))
    IO.puts("PASS shared-to-separate roles, independent addressing and USB continuity")

    assert {:ok, trial} = Network.propose(static, server)
    wait(fn -> Network.status(server).ready end)
    assert settings_http?("setup", port)
    assert :ok = Network.cancel(trial, server)
    wait(fn -> Network.ready?(Vintage.snapshot(nil), separated) end)
    assert settings_http?("setup", port)
    assert Enum.all?(Vintage.snapshot(nil).ports, &is_nil(&1.master))
    IO.puts("PASS separate-to-shared trial and rollback, USB still accessible")

    assert {:ok, trial} =
             Network.propose(
               %{separated | "eth0" => separated["eth1"], "eth1" => separated["eth0"]},
               server
             )

    wait(fn -> Network.status(server).ready end)
    assert settings_http?("setup", port)
    assert :ok = Network.cancel(trial, server)
    wait(fn -> Network.ready?(Vintage.snapshot(nil), separated) end)
    assert settings_http?("setup", port)
    IO.puts("PASS reversing port roles and restoring, without requiring an Internet lease")
  end

  defp start_web do
    for app <- [:bandit, :phoenix_live_view, :jido] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    config =
      Elixir.Config.Reader.read!(Path.expand("../../config/target.exs", __DIR__), target: :ec100)

    http = config[:nerves_gate][NervesGateWeb.Endpoint][:http]
    endpoint_config = Application.fetch_env!(:nerves_gate, NervesGateWeb.Endpoint)

    Application.put_env(
      :nerves_gate,
      NervesGateWeb.Endpoint,
      Keyword.merge(endpoint_config, http: Keyword.put(http, :port, 0), server: true)
    )

    start_supervised!(NervesGateWeb.Endpoint)
    {:ok, {_ip, port}} = NervesGateWeb.Endpoint.server_info(:http)
    port
  end

  defp settings_http?(namespace, port, address \\ "172.30.0.1") do
    {body, code} =
      System.cmd(
        "ip",
        [
          "netns",
          "exec",
          namespace,
          "curl",
          "--noproxy",
          "*",
          "-fsS",
          "--max-time",
          "2",
          "http://#{address}:#{port}/settings/network"
        ],
        stderr_to_stdout: true
      )

    # Both the editable form and an active rollback trial keep this diagnostics section.
    code == 0 and body =~ "id=\"connection-details\""
  end

  defp cmd(command, args) do
    {output, status} = System.cmd(command, args, stderr_to_stdout: true)
    assert status == 0, "#{command} #{Enum.join(args, " ")}: #{output}"
  end

  defp ping?(address),
    do: elem(System.cmd("ping", ["-c", "1", "-W", "1", address], stderr_to_stdout: true), 1) == 0

  defp wait(fun, attempts \\ 200)
  defp wait(fun, 0), do: assert(fun.(), inspect(Vintage.snapshot(nil), pretty: true))

  defp wait(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(200)
          wait(fun, attempts - 1)
        )
  end
end
