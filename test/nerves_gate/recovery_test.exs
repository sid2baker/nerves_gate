defmodule NervesGate.RecoveryTest do
  use ExUnit.Case, async: true

  alias NervesGate.Commissioning.Access

  test "recovery prefers spare Ethernet and can also enable Wi-Fi" do
    interfaces = [
      %{name: "eth0", kind: :ethernet},
      %{name: "eth1", kind: :ethernet},
      %{name: "wlan0", kind: :wifi}
    ]

    candidates = Access.commissioning_candidates(interfaces, "eth0")
    assert Enum.any?(candidates, &(&1.name == "eth1"))
    assert Enum.any?(candidates, &(&1.name == "wlan0"))
  end

  test "the known uplink is preserved independently from setup progress" do
    root = NervesGate.TestScenario.temporary_root(:recovery_network)
    :ok = NervesGate.Store.initialize(root)
    config = NervesGate.TestScenario.dhcp()

    assert :ok = NervesGate.Store.write_network(config, root)
    assert :ok = NervesGate.Store.write_phase(:recovery, root)
    assert {:ok, ^config} = NervesGate.Store.read_network(root)
    assert {:ok, %{"phase" => "recovery"}} = NervesGate.Store.read_setup(root)
  end
end
