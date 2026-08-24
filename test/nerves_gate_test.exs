defmodule NervesGateTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.Data

  test "exposes canonical gateway state without a compatibility projection" do
    assert %Data{} = NervesGate.device_state()
    assert %{configured: configured} = NervesGate.configuration()
    assert is_boolean(configured)
    assert is_map(NervesGate.replicas())
  end
end
