# reach:disable-for-this-file redundant_computation -- identities/1 re-reads guest NICs after each change
defmodule NervesGate.Scenarios.Topology do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def spec,
    do: %{
      name: "Internet moves between stable LAN ports; equipment and management cannot forward",
      fresh_disk: true
    }

  def run(%{device: vm}) do
    assert_frame_policy()
    assert NervesGate.TestQemu.topology(vm) == NervesGate.Simulator.Network.baseline()
    original = identities(vm)
    factory = Qemu.status(vm).network.desired
    assert factory == %{"mode" => "unconfigured"}
    online(vm, "eth0")

    assert {:ok, destination} = :erpc.call(vm.node, :inet, :getaddr, [~c"example.com", :inet])

    Qemu.network(vm, %{internet: :lan2})
    assert NervesGate.TestQemu.topology(vm) == %{lan1: :equipment, lan2: :internet}
    online(vm, "eth1")
    assert Qemu.status(vm).network.desired == factory
    assert identities(vm) == original

    # Supply a deliberately tempting gateway on the equipment LAN. Even a
    # manually injected route must not turn equipment into a second uplink.
    configured =
      Map.put(settings("eth1"), "eth0", %{
        "role" => "equipment",
        "address" => %{
          "ip_method" => "static",
          "static_ip" => "10.0.3.15",
          "subnet_mask" => "255.255.255.0",
          "gateway" => nil
        }
      })

    save(vm, configured)
    online(vm, "eth1")
    refuses_forwarding(vm, "eth0", "10.0.3.2", destination)
    refuses_forwarding(vm, "eth2", "192.168.77.1", destination)
    refuses_host_loopback(vm)

    Qemu.network(vm, %{internet: :off})
    assert NervesGate.TestQemu.topology(vm) == %{lan1: :equipment, lan2: :equipment}
    assert {:error, _} = Qemu.internet_request(vm, 3_000)
    assert Qemu.status(vm).backend.available
    assert Qemu.status(vm).network.desired == configured
    assert identities(vm) == original

    Qemu.network(vm, %{internet: :lan1})
    assert Qemu.status(vm).network.desired == configured
    save(vm, settings("eth0"))
    online(vm, "eth0")
    assert identities(vm) == original
  end

  # Small admission checks live with the same scenario, not a mock-network suite.
  # QEMU remains responsible for checksums and complete protocol validation.
  def assert_frame_policy do
    alias NervesGate.Simulator.Network.Ethernet
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
          {0x0A00020F, 0xC0A84D02, 6, 0, tcp, :deny},
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
    assert_management_policy()
    :ok
  end

  defp assert_management_policy do
    alias NervesGate.Simulator.Network.Ethernet

    for {port, flags, target, expected} <- [
          {9100, 0x12, 0xC0A84D01, :local},
          {4369, 0x10, 0xC0A84D01, :local},
          {4000, 0x11, 0xC0A84D01, :local},
          {22, 0x10, 0xC0A84D01, :local},
          {22, 0x02, 0xC0A84D01, :deny},
          {80, 0x10, 0xC0A84D01, :deny},
          {22, 0x10, 0x01010101, :deny}
        ] do
      tcp = <<port::16, 12_345::16, 0::64, 0x50, flags, 0::48>>

      frame =
        <<0::96, 0x0800::16, 0x45, 0, 40::16, 0::32, 64, 6, 0::16, 0xC0A84D02::32, target::32,
          tcp::binary>>

      assert Ethernet.classify(frame, :management) == expected
    end

    for {network, source, target, expected} <- [
          {:internet, 0, 0x0A000202, :local},
          {:internet, 0xC0A84D02, 0x0A000202, :deny},
          {:management, 0xC0A84D02, 0xC0A84D01, :local},
          {:management, 0xC0A84D02, 0x0A000202, :deny}
        ] do
      arp =
        <<0::96, 0x0806::16, 1::16, 0x0800::16, 6, 4, 1::16, 0::48, source::32, 0::48,
          target::32>>

      assert Ethernet.classify(arp, network) == expected
    end
  end

  defp refuses_host_loopback(vm) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])

    try do
      {:ok, port} = :inet.port(listener)
      before = NervesGate.TestQemu.network_stats(vm).denied

      assert {:error, _} =
               :erpc.call(
                 vm.node,
                 :gen_tcp,
                 :connect,
                 [{10, 0, 2, 2}, port, [:binary, active: false], 1000],
                 2000
               )

      assert NervesGate.TestQemu.network_stats(vm).denied > before
      assert {:error, :timeout} = :gen_tcp.accept(listener, 100)
    after
      :gen_tcp.close(listener)
    end
  end

  defp online(vm, port) do
    Qemu.await(
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
      {:ok, mac} = :erpc.call(vm.node, File, :read, ["/sys/class/net/#{interface}/address"])
      {:ok, index} = :erpc.call(vm.node, File, :read, ["/sys/class/net/#{interface}/ifindex"])
      {interface, {mac, index}}
    end)
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
    before = NervesGate.TestQemu.network_stats(vm).rejected[port]
    neighbor(vm, :replace, interface, gateway, mac)

    try do
      assert {_, 0} = :erpc.call(vm.node, System, :cmd, ["ip", ["route", "add" | route]])

      try do
        assert {:error, _} =
                 :erpc.call(
                   vm.node,
                   :gen_tcp,
                   :connect,
                   [destination, 443, [:binary, active: false], 2000],
                   3000
                 )

        assert NervesGate.TestQemu.network_stats(vm).rejected[port] > before
        assert :erpc.call(vm.node, Node, :alive?, [])
      after
        assert {_, 0} = :erpc.call(vm.node, System, :cmd, ["ip", ["route", "del" | route]])
      end
    after
      neighbor(vm, :delete, interface, gateway, mac)
    end
  end

  defp router_mac(vm, interface, address) do
    {:ok, table} = :erpc.call(vm.node, File, :read, ["/proc/net/arp"])

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

    attrs =
      <<8::native-16, 1::native-16, ip::binary, 10::native-16, 2::native-16, mac::binary, 0::16>>

    code =
      quote do
        index =
          File.read!("/sys/class/net/#{unquote(interface)}/ifindex")
          |> String.trim()
          |> String.to_integer()

        # Native sockaddr_nl: padding, kernel PID, multicast groups.
        kernel = %{family: 16, addr: <<0::16, 0::native-32, 0::native-32>>}
        {:ok, socket} = :socket.open(16, :raw, 0)

        try do
          message =
            <<48::native-32, unquote(type)::native-16, unquote(flags)::native-16, 1::native-32,
              0::native-32, 2, 0, 0::16, index::native-32, 0x80::native-16, 0, 1,
              unquote(attrs)::binary>>

          :ok = :socket.sendto(socket, message, kernel, 2000)

          {:ok, <<_::32, 2::native-16, _::16, 1::native-32, _::32, 0::native-32, _::binary>>} =
            :socket.recv(socket, 0, 2000)

          :ok
        after
          :socket.close(socket)
        end
      end

    assert {:ok, _bindings} = :erpc.call(vm.node, Code, :eval_quoted, [code], 3000)
  end
end
