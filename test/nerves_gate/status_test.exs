defmodule NervesGate.StatusTest do
  use ExUnit.Case

  alias NervesGate.Status

  test "the compatibility snapshot projects authoritative DeviceState" do
    public = NervesGate.DeviceState.Server.public()
    snapshot = Status.snapshot()

    assert snapshot.device_state.local.device_id == public.device_id
    assert snapshot.device["name"] == public.name
    assert snapshot.alarms == public.alarms
    refute Map.has_key?(snapshot.device_state.local, :cookie)
  end
end
