defmodule NervesGate.Scenarios.DevDiscovery do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.DevDiscovery
  alias NervesGate.TestQemu, as: Qemu

  @guest NervesGate.TestQemu.guest()
  @guest_ip {127, 0, 0, 1}

  def name,
    do: "Development discovery authenticates gateways and selects only the requested target"

  def run(vm) do
    assert Qemu.status(vm).system.node == @guest
    assert {:ok, @guest_ip} = DevDiscovery.node_address(Atom.to_string(@guest))
    assert :error = DevDiscovery.node_address("other@192.168.77.2")
    assert :error = DevDiscovery.node_address("nerves_gate@999.168.77.2")
    assert :error = DevDiscovery.node_address("nerves_gate@ec100.example.ts.net")

    # OTP consumes the port at BEAM startup, not when distribution starts.
    assert :init.get_argument(:epmd_port) == {:ok, [[Integer.to_charlist(vm.forwards.epmd)]]}
    assert {:port, 9100, _} = :erl_epmd.port_please(~c"nerves_gate", @guest_ip, 2000)

    # The session's EPMD forward reaches the real guest, not workstation EPMD.
    # The outbound-only controller does not register a service there.
    assert :noport = :erl_epmd.port_please(~c"gateway_test", @guest_ip, 2000)
    assert [gateway] = DevDiscovery.discover([@guest_ip, @guest_ip])
    assert gateway == %{node: @guest, target: :x86_64}
    assert {:ok, @guest} = DevDiscovery.select([gateway], :x86_64)
    assert {:error, :not_found} = DevDiscovery.select([gateway], :ec100)
    assert {:error, :not_found} = DevDiscovery.select([], :ec100)
    assert {:ok, @guest} = DevDiscovery.select([gateway, gateway], :x86_64)

    # Selection is pure: verify ambiguity without inventing a second device or
    # probing any unrelated service.
    other = %{gateway | node: node()}
    assert {:error, {:multiple, nodes}} = DevDiscovery.select([gateway, other], :x86_64)
    assert nodes == Enum.sort([@guest, node()])
    assert @guest in Node.list(:connected)
  end
end
