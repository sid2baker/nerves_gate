defmodule NervesGate.StatusTest do
  use ExUnit.Case

  alias NervesGate.Status

  test "the compatibility snapshot projects authoritative DeviceState" do
    data = NervesGate.DeviceState.Server.data()
    snapshot = Status.snapshot()

    assert snapshot.device_state.local.device_id == data.device_id
    assert snapshot.device["name"] == data.name
    assert snapshot.alarms == data.alarms
    refute Map.has_key?(snapshot.device_state.local, :cookie)
  end
end
