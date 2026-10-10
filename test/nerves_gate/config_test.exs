defmodule NervesGate.ConfigTest do
  use ExUnit.Case, async: true
  alias NervesGate.Config

  @static %{
    "ip_method" => "static",
    "static_ip" => "192.168.10.2",
    "subnet_mask" => "255.255.255.0",
    "gateway" => "192.168.10.1"
  }

  test "new gateways leave Ethernet unassigned" do
    assert {:ok, config} = Config.validate(Config.defaults())
    assert config["version"] == 2
    assert config["network"] == %{"mode" => "unconfigured"}
    assert {:ok, ^config} = Config.load("/nonexistent/nerves_gate.json")
  end

  test "version 1 migration preserves existing shared network and other settings" do
    old = %{Config.defaults() | "version" => 1, "network" => @static, "setup_completed" => true}
    assert {:ok, migrated} = Config.validate(old)
    assert migrated["network"] == %{"mode" => "shared", "equipment" => @static}
    assert migrated["setup_completed"]
    assert migrated["mobile"] == old["mobile"]
    assert migrated["vpn"] == old["vpn"]
    assert {:error, _} = Config.validate(Map.put(old, "secret", "no"))
  end

  test "static address accepts optional gateway and masks are contiguous" do
    assert {:ok, @static} = Config.validate_address(@static)
    assert {:ok, %{"gateway" => nil}} = Config.validate_address(%{@static | "gateway" => ""})
    assert {:ok, 24} = Config.prefix_length("255.255.255.0")
    assert {:ok, 16} = Config.prefix_length("255.255.0.0")
  end

  test "reject invalid, network, broadcast, multicast, loopback and off-subnet addresses" do
    for ip <- [
          "bad",
          "192.168.1",
          "192.168.10.0",
          "192.168.10.255",
          "224.0.0.1",
          "127.0.0.1",
          "0.1.2.3"
        ] do
      assert {:error, _} = Config.validate_address(%{@static | "static_ip" => ip})
    end

    for mask <- ["255.0.255.0", "255.255.255.255", "0.0.0.0", nil] do
      assert {:error, _} = Config.validate_address(%{@static | "subnet_mask" => mask})
    end

    for gateway <- ["192.168.11.1", "192.168.10.255", "192.168.10.2", "192.168.10.0", "::1"] do
      assert {:error, _} = Config.validate_address(%{@static | "gateway" => gateway})
    end
  end

  test "DHCP clears manual fields and rejects unknown keys" do
    assert {:ok, address} = Config.validate_address(%{@static | "ip_method" => "dhcp"})
    assert address == Config.address_defaults()
    assert {:error, _} = Config.validate_address(Map.put(address, "dhcp_server", true))
  end

  test "separate roles require explicit port and manual equipment address without default route" do
    network = %{
      "mode" => "ethernet",
      "internet_port" => "eth0",
      "equipment" => %{@static | "gateway" => nil}
    }

    assert {:ok, ^network} = Config.validate_network(network)
    assert {:ok, _} = Config.validate_network(%{network | "internet_port" => "eth1"})

    for invalid <- [
          @static,
          %{},
          %{network | "internet_port" => "usb0"},
          %{network | "equipment" => @static},
          %{network | "equipment" => Config.address_defaults()},
          Map.put(network, "nat", true),
          %{network | "mode" => "mobile"}
        ] do
      assert {:error, _} = Config.validate_network(invalid)
    end
  end

  test "overlap compares different prefix sizes" do
    assert Config.overlap?("10.1.2.3", 16, "10.1.9.1", 24)
    refute Config.overlap?("10.1.2.3", 24, "10.1.9.1", 24)
    refute Config.overlap?("bad", 24, "10.1.9.1", 24)
  end

  test "reject unsupported version, unknown data and credentials" do
    for config <- [
          nil,
          [],
          %{},
          %{Config.defaults() | "version" => 99},
          Map.put(Config.defaults(), "status", %{}),
          put_in(Config.defaults(), ["mobile", "pin"], "1234")
        ] do
      assert {:error, _} = Config.validate(config)
    end
  end

  @tag :tmp_dir
  test "atomic private file preserves confirmed config on invalid write", %{tmp_dir: dir} do
    path = Path.join(dir, "nerves_gate.json")
    config = %{Config.defaults() | "network" => %{"mode" => "shared", "equipment" => @static}}
    assert :ok = Config.save(config, path)
    assert {:ok, ^config} = Config.load(path)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert {:error, _} = Config.save(%{"version" => 99}, path)
    assert {:ok, ^config} = Config.load(path)
    assert File.ls!(dir) == ["nerves_gate.json"]
    File.write!(path, "broken JSON")
    assert {:error, _} = Config.load(path)
  end
end
