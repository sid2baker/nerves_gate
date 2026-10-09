# Invoked ONLY by scripts/test_bridge.sh, inside its empty network/mount namespaces.
if File.read_link!("/proc/self/ns/net") == System.fetch_env!("NERVES_GATE_HOST_NETNS"),
  do: raise("Refusing host network")

ExUnit.start()
Application.ensure_all_started(:logger)
Application.ensure_all_started(:phoenix_pubsub)
Application.ensure_all_started(:jason)
Application.load(:vintage_net)

for {key, value} <- [
      persistence: VintageNet.Persistence.Null,
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

    static = %{
      "ip_method" => "static",
      "static_ip" => "10.45.0.10",
      "subnet_mask" => "255.255.255.0",
      "gateway" => nil
    }

    config = %{Config.defaults() | "network" => static}
    :ok = Config.save(config, "/run/nerves_gate.json")

    server =
      start_supervised!(
        {Network, path: "/run/nerves_gate.json", adapter: {Vintage, nil}, poll_ms: 100}
      )

    wait(fn -> Network.ready?(Vintage.snapshot(nil), static) end)
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

    assert {:ok, trial} = Network.propose(Config.defaults()["network"], server)
    wait(fn -> Network.status(server).ready end)
    assert :ok = Network.confirm(trial, server)
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
    :sys.replace_state(server, &%{&1 | trial_ms: 1_000})
    assert {:ok, _} = Network.propose(%{static | "static_ip" => "10.45.0.20"}, server)
    wait(fn -> Network.status(server).trial == nil end)
    wait(fn -> Network.ready?(Vintage.snapshot(nil), static) end)
    wait(fn -> ping?("10.45.0.3") end)
    assert {:ok, saved} = Config.load("/run/nerves_gate.json")
    assert saved["network"] == static
    IO.puts("PASS timed rollback and durable confirmed configuration")

    assert {:ok, _} = Network.propose(%{static | "static_ip" => "10.45.0.30"}, server)
    stop_supervised!(Network)

    server =
      start_supervised!(
        {Network, path: "/run/nerves_gate.json", adapter: {Vintage, nil}, poll_ms: 100}
      )

    wait(fn -> Network.ready?(Vintage.snapshot(nil), static) end)
    assert Network.status(server).trial == nil
    assert File.read!("/sys/class/net/br0/ifindex") == bridge_index
    assert ping?("10.45.0.2")
    IO.puts("PASS manager restart restores confirmed IP without recreating the bridge")
  end

  defp cmd(command, args) do
    {output, status} = System.cmd(command, args, stderr_to_stdout: true)
    assert status == 0, "#{command} #{Enum.join(args, " ")}: #{output}"
  end

  defp ping?(address),
    do: elem(System.cmd("ping", ["-c", "1", "-W", "1", address], stderr_to_stdout: true), 1) == 0

  defp wait(fun, attempts \\ 200)
  defp wait(fun, 0), do: assert(fun.())

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
