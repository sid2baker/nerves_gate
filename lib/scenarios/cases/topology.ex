# reach:disable-for-this-file redundant_computation -- identities/1 re-reads guest NICs after each change
defmodule Scenarios.Cases.Topology do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device
  alias Scenarios.Qemu, as: Qemu

  def spec,
    do: %{
      name: "Internet moves between stable LAN ports; equipment and management cannot forward",
      fresh_disk: true,
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    assert_frame_policy()
    assert_cellular_input(vm)
    assert Scenarios.Qemu.topology(vm) == Simulator.Network.baseline()
    original = identities(vm)
    factory = Scenarios.Device.status(vm).network.desired
    assert factory == %{"mode" => "unconfigured"}
    online(vm, "eth0")

    assert {:ok, destination} =
             Scenarios.Device.rpc(vm, :inet, :getaddr, [~c"example.com", :inet])

    Qemu.network(vm, %{internet: :lan2})
    assert Scenarios.Qemu.topology(vm) == %{lan1: :plugin, lan2: :internet}
    online(vm, "eth1")
    assert Scenarios.Device.status(vm).network.desired == factory
    assert identities(vm) == original

    # Supply a deliberately tempting gateway on the equipment LAN. Even a
    # manually injected route must not turn equipment into a second uplink.
    configured =
      Map.put(settings("eth1"), "eth0", %{"role" => "plugin", "address" => nil})

    save(vm, configured)
    online(vm, "eth1")
    refuses_plugin_forwarding(vm, destination)
    refuses_forwarding(vm, "eth2", vm.management_host, destination)
    refuses_host_loopback(vm)

    Qemu.network(vm, %{internet: :off})
    assert Scenarios.Qemu.topology(vm) == %{lan1: :plugin, lan2: :plugin}
    assert {:error, _} = Qemu.internet_request(vm, 3_000)
    assert Scenarios.Device.status(vm).device.available
    assert Scenarios.Device.status(vm).network.desired == configured
    assert identities(vm) == original

    Qemu.network(vm, %{internet: :lan1})
    assert Scenarios.Device.status(vm).network.desired == configured
    save(vm, settings("eth0"))
    online(vm, "eth0")
    assert identities(vm) == original
  end

  defp assert_cellular_input(vm) do
    alias NervesGate.Network.Vintage

    before = input_rules(vm)
    assert :ok = Scenarios.Device.rpc(vm, Vintage, :prepare_cellular_input, [])
    assert input_rules(vm) == before

    for tool <- ["iptables", "ip6tables"],
        rule <- Vintage.cellular_input_rules(tool) do
      assert {_, 0} = Scenarios.Device.rpc(vm, System, :cmd, [tool, ["-C", "INPUT" | rule]])
    end
  end

  defp input_rules(vm) do
    for tool <- ["iptables", "ip6tables"] do
      {rules, 0} = Scenarios.Device.rpc(vm, System, :cmd, [tool, ["-S", "INPUT"]])
      rules
    end
  end

  # Small admission checks live with the same scenario, not a mock-network suite.
  # QEMU remains responsible for checksums and complete protocol validation.
  def assert_frame_policy do
    alias Simulator.Network.Ethernet
    tcp = <<12_345::16, 443::16, 0::128>>
    dns = <<12_345::16, 53::16, 8::16, 0::16>>
    dhcp = <<68::16, 67::16, 8::16, 0::16>>

    for {source, target, protocol, fragment, body, expected} <- [
          {0, 0xFFFFFFFF, 17, 0, dhcp, :local},
          {0x0A00020F, 0x01010101, 6, 0, tcp, :uplink},
          {0x0A00020F, 0x0A000203, 17, 0, dns, :uplink},
          {0x0A00020F, 0x0A000203, 17, 0x2000, dns, :deny},
          {0x0A00020F, 0x0A000202, 6, 0, tcp, :deny},
          {0x0A00020F, 0x7F000001, 6, 0, tcp, :deny},
          {0x0A00020F, 0xFFFFFFFF, 6, 0, tcp, :deny},
          {0x0A00020F, 0xAC1FFF02, 6, 0, tcp, :deny},
          {0x0A00020F, 0xAC1F0001, 6, 0, tcp, :deny},
          {0x0A00020F, 0xAC1F7F81, 6, 0, tcp, :deny},
          {0xC0A84D02, 0x01010101, 6, 0, tcp, :deny}
        ] do
      frame =
        <<0::96, 0x0800::16, 0x45, 0, 20 + byte_size(body)::16, 0::16, fragment::16, 64, protocol,
          0::16, source::32, target::32, body::binary>>

      assert Ethernet.classify(frame, :internet) == expected
      assert Ethernet.classify(binary_part(frame, 0, 18), :internet) == :deny
      <<macs::binary-size(12), _type::16, ip::binary>> = frame

      assert Ethernet.classify(
               <<macs::binary, 0x8100::16, 0::16, 0x0800::16, ip::binary>>,
               :internet
             ) == :deny

      assert Ethernet.classify(<<macs::binary, 0x86DD::16, ip::binary>>, :internet) == :deny

      assert Ethernet.classify(
               <<macs::binary, 0x0800::16, 0x46, binary_part(ip, 1, byte_size(ip) - 1)::binary>>,
               :internet
             ) == :deny
    end

    assert Ethernet.classify(<<>>, :internet) == :deny
    :ok
  end

  defp refuses_host_loopback(vm) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])

    try do
      {:ok, port} = :inet.port(listener)
      before = Scenarios.Qemu.network_stats(vm).denied

      assert {:error, _} =
               Scenarios.Device.rpc(
                 vm,
                 :gen_tcp,
                 :connect,
                 [{10, 0, 2, 2}, port, [:binary, active: false], 1000],
                 2000
               )

      assert Scenarios.Qemu.network_stats(vm).denied > before
      assert {:error, :timeout} = :gen_tcp.accept(listener, 100)
    after
      :gen_tcp.close(listener)
    end
  end

  defp online(vm, port) do
    Scenarios.Device.await(
      vm,
      "Internet through #{port}",
      fn status ->
        status.connections.internet.health == "online" and
          status.connections.internet.selected == port
      end,
      60_000
    )

    assert {:ok, 200} = Qemu.internet_request(vm)
  end

  defp identities(vm) do
    Map.new(~w(eth0 eth1 eth2), fn interface ->
      {:ok, mac} = Scenarios.Device.rpc(vm, File, :read, ["/sys/class/net/#{interface}/address"])

      {:ok, index} =
        Scenarios.Device.rpc(vm, File, :read, ["/sys/class/net/#{interface}/ifindex"])

      {interface, {mac, index}}
    end)
  end

  defp refuses_plugin_forwarding(vm, destination) do
    Scenarios.ManagedPlugin.with_plugin(
      vm,
      fn owner ->
        assert {:ok, _} =
                 Scenarios.ManagedPlugin.call(vm, owner, NervesGateSDK.Network, :claim_local, [
                   "eth0",
                   "10.0.3.15",
                   24
                 ])

        Scenarios.Device.await(vm, "application local address ready", &addressed?(&1, "eth0"))
        refuses_forwarding(vm, "eth0", "10.0.3.2", destination)
      end,
      assigned_ports: ["eth0"]
    )

    Scenarios.Device.await(vm, "application lease cleaned", &(&1.network.local == nil), 75_000)
  end

  defp refuses_forwarding(vm, interface, gateway, destination) do
    address = destination |> :inet.ntoa() |> to_string()
    route = ["#{address}/32", "via", gateway, "dev", interface]

    port =
      if interface == "eth0" do
        :lan1
      else
        :management
      end

    router_interface =
      if interface == "eth0" do
        "eth1"
      else
        "eth2"
      end

    router_address =
      if interface == "eth0" do
        "10.0.2.2"
      else
        gateway
      end

    mac = router_mac(vm, router_interface, router_address)
    before = if port == :lan1, do: Scenarios.Qemu.network_stats(vm).rejected[port]
    neighbor(vm, :replace, interface, gateway, mac)

    try do
      assert {_, 0} = Scenarios.Device.rpc(vm, System, :cmd, ["ip", ["route", "add" | route]])

      try do
        assert {:error, _} =
                 Scenarios.Device.rpc(
                   vm,
                   :gen_tcp,
                   :connect,
                   [destination, 443, [:binary, active: false], 2000],
                   3000
                 )

        if port == :lan1, do: assert(Scenarios.Qemu.network_stats(vm).rejected[port] > before)
        assert Scenarios.Device.rpc(vm, Node, :alive?, [])
      after
        assert {_, 0} = Scenarios.Device.rpc(vm, System, :cmd, ["ip", ["route", "del" | route]])
      end
    after
      neighbor(vm, :delete, interface, gateway, mac)
    end
  end

  defp router_mac(vm, interface, address) do
    {:ok, table} = Scenarios.Device.rpc(vm, File, :read, ["/proc/net/arp"])

    mac =
      Enum.find_value(String.split(table, "\n"), fn line ->
        case String.split(line) do
          [^address, _, _, mac, _, ^interface] when mac != "00:00:00:00:00:00" -> mac
          _ -> nil
        end
      end)

    assert is_binary(mac), "No observed router MAC on #{interface}"
    mac
  end

  # BusyBox ip only supports neighbor show/flush. Send RTM_NEWNEIGH/DELNEIGH
  # in the owned guest, with an ACK, rather than add a host tool or fake ARP peer.
  defp neighbor(vm, operation, interface, address, mac) do
    {type, flags} = if operation == :replace, do: {28, 0x505}, else: {29, 5}
    {:ok, ip} = :inet.parse_address(String.to_charlist(address))
    ip = :erlang.list_to_binary(Tuple.to_list(ip))
    mac = mac |> String.replace(":", "") |> Base.decode16!(case: :mixed)

    index =
      vm
      |> Scenarios.Device.rpc(File, :read!, ["/sys/class/net/#{interface}/ifindex"])
      |> String.trim()
      |> String.to_integer()

    attrs =
      <<8::native-16, 1::native-16, ip::binary, 10::native-16, 2::native-16, mac::binary, 0::16>>

    body = <<2, 0, 0::16, index::native-32, 0x80::native-16, 0, 1, attrs::binary>>

    assert {:ok, []} =
             Scenarios.Device.rpc(
               vm,
               NervesGate.Linux.Netlink,
               :request,
               [type, flags, body],
               3_000
             )
  end
end
