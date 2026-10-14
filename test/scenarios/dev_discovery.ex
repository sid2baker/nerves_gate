defmodule NervesGate.Scenarios.DevDiscovery do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.DevDiscovery
  alias NervesGate.TestQemu, as: Qemu

  @guest :"nerves_gate@192.168.77.2"
  @guest_ip {192, 168, 77, 2}

  def name,
    do: "Development discovery authenticates gateways and selects only the requested target"

  def run(vm) do
    assert Qemu.status(vm).system.node == @guest
    assert {:ok, @guest_ip} = DevDiscovery.node_address(Atom.to_string(@guest))
    assert :error = DevDiscovery.node_address("other@192.168.77.2")
    assert :error = DevDiscovery.node_address("nerves_gate@999.168.77.2")
    assert :error = DevDiscovery.node_address("nerves_gate@ec100.example.ts.net")

    # Probe only the owned namespace: the real guest and its controller, which
    # runs distribution but does not register the nerves_gate service in EPMD.
    assert [gateway] = DevDiscovery.discover([@guest_ip, {192, 168, 77, 1}, @guest_ip])
    assert gateway == %{node: @guest, target: :x86_64}
    assert {:ok, @guest} = DevDiscovery.select([gateway], :x86_64)
    assert {:error, :not_found} = DevDiscovery.select([gateway], :ec100)
    assert {:error, :not_found} = DevDiscovery.select([], :ec100)
    assert {:ok, @guest} = DevDiscovery.select([gateway, gateway], :x86_64)

    # Selection is pure: verify ambiguity without inventing a second device or
    # probing anything outside the disposable namespace.
    other = %{gateway | node: node()}
    assert {:error, {:multiple, nodes}} = DevDiscovery.select([gateway, other], :x86_64)
    assert nodes == Enum.sort([@guest, node()])
    assert @guest in Node.list()
  end
end
