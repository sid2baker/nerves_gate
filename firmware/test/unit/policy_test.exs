defmodule NervesGate.PolicyTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Config, Network}
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

  test "Ethernet configurations never create a metadata bridge" do
    network = %{
      "mode" => "ports",
      "eth0" => %{"role" => "internet", "address" => Config.address_defaults()},
      "eth1" => nil
    }

    for current <- [Config.defaults()["network"], network] do
      configs = current |> NervesGate.Network.Vintage.configurations() |> Map.new()
      assert Enum.sort(Map.keys(configs)) == Enum.sort(NervesGate.Board.ethernet())
      refute Map.has_key?(configs, "br0")
    end

    assert_raise ArgumentError, fn ->
      NervesGate.Network.LAN.normalize(%{vintage_net_bridge: %{interfaces: ["eth0", "eth1"]}})
    end
  end

  test "4G supports only isolated plugin links and rejects joined settings" do
    plugin = %{"role" => "plugin", "address" => nil}

    network = %{
      "mode" => "ports",
      "eth0" => plugin,
      "eth1" => plugin,
      "internet" => %{"mode" => "cellular", "apn" => ""}
    }

    assert {:ok, ^network} = Config.validate_network(network)
    configs = NervesGate.Network.Vintage.configurations(network)
    refute List.keymember?(configs, "br0", 0)

    for unsupported <- [
          %{"mode" => "shared", "equipment" => Config.address_defaults()},
          %{network | "eth1" => %{"role" => "equipment", "address" => Config.address_defaults()}}
        ] do
      assert {:error, reason} = Config.validate_network(unsupported)
      assert reason =~ "never rewritten"
    end
  end

  describe "network topology readiness" do
    setup do
      port = %{
        name: "eth0",
        present: true,
        state: :configured,
        master: nil,
        method: "dhcp",
        addresses: []
      }

      network = %{
        "mode" => "ports",
        "eth0" => %{"role" => "internet", "address" => Config.address_defaults()}
      }

      {:ok, port: port, network: network}
    end

    test "DHCP needs configured independent topology, not a lease", %{
      port: port,
      network: network
    } do
      assert Network.ready?(%{ports: [port]}, network)

      for unavailable <- [
            %{port | present: false},
            %{port | state: :configuring},
            %{port | master: "br0"},
            %{port | method: "static"}
          ] do
        refute Network.ready?(%{ports: [unavailable]}, network)
      end
    end

    test "static addressing needs the matching address and prefix", %{
      port: port,
      network: network
    } do
      address = %{
        "ip_method" => "static",
        "static_ip" => "192.0.2.10",
        "subnet_mask" => "255.255.255.0"
      }

      network = put_in(network, ["eth0", "address"], address)
      port = %{port | method: "static"}
      matching = %{address: "192.0.2.10", prefix_length: 24}

      assert Network.ready?(%{ports: [%{port | addresses: [matching]}]}, network)

      for addresses <- [
            [],
            [%{matching | address: "192.0.2.11"}],
            [%{matching | prefix_length: 25}]
          ] do
        refute Network.ready?(%{ports: [%{port | addresses: addresses}]}, network)
      end
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
