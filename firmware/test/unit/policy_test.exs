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
      assert Labels.normalize(label) ==
               {:error,
                %{
                  code: "invalid_label",
                  message: "Use a label of at most 64 characters without control characters."
                }}
    end

    labels = Map.new(1..256, &{to_string(&1), "label"})

    assert Labels.put(labels, "new", "label") ==
             {:error,
              %{
                code: "label_limit",
                message: "The 256-label limit has been reached. Remove an unused label first."
              }}

    assert {:ok, updated} = Labels.put(labels, "1", "")
    refute Map.has_key?(updated, "1")
    assert {:ok, _} = Labels.put(labels, "1", "replacement")
  end

  test "4G Internet can leave both Ethernet ports on one local network without an uplink" do
    address = %{
      "ip_method" => "static",
      "static_ip" => "192.168.10.2",
      "subnet_mask" => "255.255.255.0",
      "gateway" => nil
    }

    network = %{
      "mode" => "shared",
      "equipment" => address,
      "internet" => %{"mode" => "cellular", "apn" => ""}
    }

    assert {:ok, validated} = Config.validate_network(network)
    configs = NervesGate.Network.Vintage.configurations(validated)
    {"br0", bridge} = List.keyfind(configs, "br0", 0)
    assert bridge.vintage_net_bridge.interfaces == ["eth0", "eth1"]
    assert bridge.ipv4.method == :static
    refute Map.has_key?(bridge.ipv4, :gateway)
    refute Map.has_key?(bridge.ipv4, :name_servers)

    for invalid <- [
          Config.address_defaults(),
          Map.put(address, "gateway", "192.168.10.1"),
          Map.put(address, "nameservers", ["192.168.10.1"])
        ] do
      assert {:error, message} = Config.validate_network(%{network | "equipment" => invalid})
      assert message =~ "4G-only Internet"
    end

    uplink = %{"role" => "internet", "address" => Config.address_defaults()}

    assert {:error, _} =
             Config.validate_network(%{
               "mode" => "ports",
               "eth0" => uplink,
               "eth1" => nil,
               "internet" => network["internet"]
             })
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
