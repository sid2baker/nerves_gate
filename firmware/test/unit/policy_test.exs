defmodule NervesGate.PolicyTest do
  use ExUnit.Case, async: true
  alias NervesGate.Config
  alias NervesGate.Equipment.Labels
  alias NervesGate.Indicators.Policy

  test "unknown connectivity is never indicated as healthy" do
    alarms = %{connection: false, severity: :none}
    remote = %{available: true, state: "online", auth_state: "authenticated", health: []}
    assert Policy.normal(remote, true, alarms) == %{run: :solid, user1: :solid, user2: :off}
    assert Policy.remote_pattern(remote, nil, alarms) == :slow
    assert Policy.remote_pattern(remote, true, %{alarms | connection: true}) == :fast
    assert Policy.remote_pattern(%{operation: "disconnect"}, true, alarms) == :off
    assert Policy.alarm_pattern(%{severity: :error}) == :fast
    assert Policy.override(%{}, :reset) == %{run: :fast, user1: :fast, user2: :fast}
  end

  test "LED phases use monotonic time, including negative timestamps" do
    for time <- [-1_001, -1, 0, 124, 125, 499, 500, 1_000] do
      assert Policy.value(:slow, time) in [0, 1]
      assert Policy.value(:fast, time) in [0, 1]
      assert Policy.value(:off, time) == 0
      assert Policy.value(:solid, time) == 1
    end

    assert Policy.value(:slow, 0) != Policy.value(:slow, 500)
    assert Policy.value(:fast, 0) != Policy.value(:fast, 125)
  end

  test "label validation and capacity are independent of persistence" do
    assert Labels.normalize("  Pump  ") == {:ok, "Pump"}

    for label <- [nil, <<255>>, "bad\nlabel", String.duplicate("x", 65)] do
      assert Labels.normalize(label) == {:error, :invalid_label}
    end

    labels = Map.new(1..256, &{to_string(&1), "label"})
    assert Labels.put(labels, "new", "label") == {:error, :label_limit}
    assert {:ok, updated} = Labels.put(labels, "1", "")
    refute Map.has_key?(updated, "1")
    assert {:ok, _} = Labels.put(labels, "1", "replacement")
  end

  test "network input validation rejects unknown keys and invalid roles" do
    assert Config.validate_address(%{"ip_method" => "dhcp"}) == {:ok, Config.address_defaults()}
    assert {:error, _} = Config.validate_address(%{"ip_method" => "dhcp", "command" => "run"})
    assert {:error, _} = Config.validate_network(nil)
    port = %{"role" => "internet", "address" => %{"ip_method" => "dhcp"}}

    assert {:error, _} =
             Config.validate_network(%{"mode" => "ports", "eth0" => port, "eth1" => port})

    assert {:ok, _} = Config.validate_network(%{"mode" => "ports", "eth0" => port, "eth1" => nil})

    assert Config.role_port(%{"mode" => "ports", "eth0" => port, "eth1" => nil}, "internet") ==
             "eth0"
  end
end
