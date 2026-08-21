defmodule NervesGateTest do
  use ExUnit.Case, async: true

  test "returns a diagnostic status snapshot" do
    status = NervesGate.status()
    assert status.identity.hostname =~ "nervesgate-"
    assert is_list(status.alarms)
  end
end
