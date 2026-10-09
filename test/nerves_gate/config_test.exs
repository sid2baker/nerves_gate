defmodule NervesGate.ConfigTest do
  use ExUnit.Case, async: true
  alias NervesGate.Config

  @static %{
    "ip_method" => "static",
    "static_ip" => "192.168.10.2",
    "subnet_mask" => "255.255.255.0",
    "gateway" => "192.168.10.1"
  }

  test "default configuration is valid and missing files use defaults" do
    assert {:ok, config} = Config.validate(Config.defaults())
    assert config["network"]["ip_method"] == "dhcp"
    assert {:ok, ^config} = Config.load("/nonexistent/nerves_gate.json")
  end

  test "static address accepts optional gateway and masks are contiguous" do
    assert {:ok, @static} = Config.validate_network(@static)
    assert {:ok, %{"gateway" => nil}} = Config.validate_network(%{@static | "gateway" => ""})
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
      assert {:error, _} = Config.validate_network(%{@static | "static_ip" => ip})
    end

    for mask <- ["255.0.255.0", "255.255.255.255", "0.0.0.0", nil] do
      assert {:error, _} = Config.validate_network(%{@static | "subnet_mask" => mask})
    end

    for gateway <- ["192.168.11.1", "192.168.10.255", "192.168.10.2", "192.168.10.0", "::1"] do
      assert {:error, _} = Config.validate_network(%{@static | "gateway" => gateway})
    end
  end

  test "DHCP clears manual fields and rejects unknown keys" do
    assert {:ok, network} = Config.validate_network(%{@static | "ip_method" => "dhcp"})
    assert network == Config.defaults()["network"]
    assert {:error, _} = Config.validate_network(Map.put(network, "dhcp_server", true))
  end

  test "reject unsupported version, unknown data and credentials" do
    for config <- [
          nil,
          [],
          %{},
          %{Config.defaults() | "version" => 2},
          Map.put(Config.defaults(), "status", %{}),
          put_in(Config.defaults(), ["mobile", "pin"], "1234")
        ] do
      assert {:error, _} = Config.validate(config)
    end
  end

  @tag :tmp_dir
  test "atomic private file preserves confirmed config on invalid write", %{tmp_dir: dir} do
    path = Path.join(dir, "nerves_gate.json")
    config = %{Config.defaults() | "network" => @static}
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
