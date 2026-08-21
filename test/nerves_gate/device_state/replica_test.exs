defmodule NervesGate.DeviceState.ReplicaTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.Public
  alias NervesGate.DeviceState.Replica
  alias NervesGate.DeviceState.Snapshot

  test "sequential operations advance a replica" do
    replica = Replica.new(:"gate-a@100.64.0.10", snapshot())

    assert {:ok, replica} =
             Replica.apply_operation(replica, "boot-a", 4, {:name_changed, "Boiler room"})

    assert replica.revision == 4
    assert replica.data.name == "Boiler room"
    assert replica.connected
  end

  test "duplicates are ignored and revision gaps require a snapshot" do
    replica = Replica.new(:"gate-a@100.64.0.10", snapshot())

    assert :duplicate =
             Replica.apply_operation(replica, "boot-a", 3, {:name_changed, "Old"})

    assert :resync =
             Replica.apply_operation(replica, "boot-a", 5, {:name_changed, "Missed revision"})
  end

  test "a changed boot id requires a new snapshot and stale data is retained" do
    replica = Replica.new(:"gate-a@100.64.0.10", snapshot())

    assert :resync =
             Replica.apply_operation(replica, "boot-b", 1, {:name_changed, "After reboot"})

    stale = Replica.disconnected(replica)
    refute stale.connected
    assert stale.data == replica.data
    assert stale.last_seen_at == replica.last_seen_at
  end

  defp snapshot do
    data = %Public{
      device_id: "gate-a",
      name: "Gate A",
      boot_id: "boot-a",
      firmware_version: "1.0.0"
    }

    %Snapshot{boot_id: "boot-a", revision: 3, data: data}
  end
end
