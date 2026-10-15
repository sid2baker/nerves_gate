defmodule NervesGate.Scenarios.Topology do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestNetwork
  alias NervesGate.TestQemu, as: Qemu

  @guest :"nerves_gate@192.168.77.2"

  def name, do: "Internet moves between stable LAN ports; equipment and management cannot forward"
  def boot_options, do: []

  def run(vm) do
    assert Qemu.topology() == TestNetwork.baseline()
    original = identities()
    factory = Qemu.status(vm).network.desired
    assert factory == %{"mode" => "unconfigured"}
    online(vm, "eth0")

    assert {:ok, destination} = :erpc.call(@guest, :inet, :getaddr, [~c"example.com", :inet])

    Qemu.connect_internet(vm, :lan2)
    assert Qemu.topology() == %{lan1: :equipment, lan2: :internet}
    online(vm, "eth1")
    assert Qemu.status(vm).network.desired == factory
    assert identities() == original

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
    refuses_forwarding("eth0", "10.0.3.2", destination)
    refuses_forwarding("eth2", "192.168.77.1", destination)

    Qemu.connect_internet(vm, :off)
    assert Qemu.topology() == %{lan1: :equipment, lan2: :equipment}
    assert {:error, _} = Qemu.internet_request(vm, 3_000)
    assert Qemu.status(vm).backend.available
    assert Qemu.status(vm).network.desired == configured
    assert identities() == original

    Qemu.connect_internet(vm, :lan1)
    assert Qemu.status(vm).network.desired == configured
    save(vm, settings("eth0"))
    online(vm, "eth0")
    assert identities() == original
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

  defp identities do
    Map.new(~w(eth0 eth1 eth2), fn interface ->
      {:ok, mac} = :erpc.call(@guest, File, :read, ["/sys/class/net/#{interface}/address"])
      {:ok, index} = :erpc.call(@guest, File, :read, ["/sys/class/net/#{interface}/ifindex"])
      {interface, {mac, index}}
    end)
  end

  defp refuses_forwarding(interface, gateway, destination) do
    address = destination |> :inet.ntoa() |> to_string()
    route = ["#{address}/32", "via", gateway, "dev", interface]
    before = TestNetwork.forwarding_drops()
    assert {_, 0} = :erpc.call(@guest, System, :cmd, ["ip", ["route", "add" | route]])

    try do
      assert {:error, _} =
               :erpc.call(
                 @guest,
                 :gen_tcp,
                 :connect,
                 [destination, 443, [:binary, active: false], 2_000],
                 3_000
               )

      assert TestNetwork.forwarding_drops() > before
      assert :erpc.call(@guest, Node, :alive?, [])
    after
      assert {_, 0} = :erpc.call(@guest, System, :cmd, ["ip", ["route", "del" | route]])
    end
  end
end
