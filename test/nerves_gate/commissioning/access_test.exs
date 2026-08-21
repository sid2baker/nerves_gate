defmodule NervesGate.Commissioning.AccessTest do
  use ExUnit.Case

  alias NervesGate.Commissioning.Access
  alias NervesGate.TestNetworkAdapter

  setup do
    {:ok, _pid} = TestNetworkAdapter.reset()
    :ok
  end

  test "commissioning uses Wi-Fi AP and spare Ethernet simultaneously" do
    hardware = fn ->
      [
        %{name: "eth0", kind: :ethernet},
        %{name: "eth1", kind: :ethernet},
        %{name: "wlan0", kind: :wifi}
      ]
    end

    {:ok, pid} =
      Access.start_link(name: unique_name(), adapter: TestNetworkAdapter, hardware: hardware)

    assert {:ok, active} = Access.enable(:commissioning, "eth0", pid)
    assert Enum.map(active, & &1.interface) == ["wlan0", "eth1"]
    assert Enum.all?(active, &String.starts_with?(&1.address, "192.168."))
    assert Enum.find(active, &(&1.interface == "wlan0")).ssid =~ "NervesGate-"

    assert :ok = Access.release("eth1", pid)
    assert Enum.map(Access.status(pid).active, & &1.interface) == ["wlan0"]
    assert :ok = Access.disable(pid)
    refute {:clear, "eth1"} in TestNetworkAdapter.state().calls
  end

  test "commissioning without Wi-Fi falls back to eth1 and preserves eth0 uplink" do
    interfaces = [
      %{name: "eth0", kind: :ethernet},
      %{name: "eth1", kind: :ethernet},
      %{name: "eth2", kind: :ethernet}
    ]

    assert Enum.map(Access.commissioning_candidates(interfaces, "eth0"), & &1.name) == [
             "eth1",
             "eth2"
           ]
  end

  test "only possible Internet uplink is never consumed for commissioning" do
    assert Access.commissioning_candidates([%{name: "eth0", kind: :ethernet}], nil) == []
  end

  defp unique_name, do: String.to_atom("access_#{System.unique_integer([:positive])}")
end
