defmodule NervesGate.PolicyTest do
  use ExUnit.Case, async: true
  alias NervesGate.Config
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

  test "equipment registry and compatibility SDK modules are absent" do
    refute Code.ensure_loaded?(NervesGate.Equipment)
    refute Code.ensure_loaded?(NervesGateSDK.Equipment)
    refute Map.has_key?(NervesGate.Status.disconnected(), :equipment)
  end

  test "current independent network settings round-trip without role adaptation" do
    internet = %{"role" => "internet", "address" => Config.address_defaults()}
    network = %{"mode" => "ports", "eth0" => internet, "eth1" => nil}

    for current <- [Config.defaults()["network"], network] do
      configs = current |> NervesGate.Network.Vintage.configurations() |> Map.new()
      assert {:ok, ^current} = NervesGate.Network.Vintage.from_configurations(configs)
    end

    configs = network |> NervesGate.Network.Vintage.configurations() |> Map.new()
    unknown = put_in(configs["eth0"][:nerves_gate_role], "unsupported")
    assert {:error, _} = NervesGate.Network.Vintage.from_configurations(unknown)
    joined = put_in(configs["br0"][:vintage_net_bridge][:interfaces], ["eth0", "eth1"])
    assert {:error, _} = NervesGate.Network.Vintage.from_configurations(joined)
    assert_raise ArgumentError, fn -> NervesGate.Network.LAN.normalize(joined["br0"]) end
  end

  test "4G supports only isolated application links and rejects legacy joined settings" do
    application = %{"role" => "plugin", "address" => nil}

    network = %{
      "mode" => "ports",
      "eth0" => application,
      "eth1" => application,
      "internet" => %{"mode" => "cellular", "apn" => ""}
    }

    assert {:ok, ^network} = Config.validate_network(network)
    configs = NervesGate.Network.Vintage.configurations(network)
    {"br0", bridge} = List.keyfind(configs, "br0", 0)
    assert bridge.vintage_net_bridge.interfaces == []

    for legacy <- [
          %{"mode" => "shared", "equipment" => Config.address_defaults()},
          %{network | "eth1" => %{"role" => "equipment", "address" => Config.address_defaults()}}
        ] do
      assert {:error, reason} = Config.validate_network(legacy)
      assert reason =~ "migration"
    end
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
