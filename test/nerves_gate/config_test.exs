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
    assert Config.defaults() == %{
             "setup_completed" => false,
             "network" => %{"mode" => "unconfigured"}
           }
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
      "mode" => "ports",
      "eth0" => %{"role" => "internet", "address" => NervesGate.Config.address_defaults()},
      "eth1" => %{"role" => "equipment", "address" => %{@static | "gateway" => nil}}
    }

    assert {:ok, ^network} = Config.validate_network(network)

    assert {:ok, _} =
             Config.validate_network(%{
               network
               | "eth0" => network["eth1"],
                 "eth1" => network["eth0"]
             })

    for invalid <- [
          @static,
          %{},
          Map.put(network, "usb0", network["eth0"]),
          put_in(network, ["eth1", "address"], @static),
          put_in(network, ["eth1", "address"], Config.address_defaults()),
          put_in(network, ["eth1", "address", "nameservers"], ["1.1.1.1"]),
          %{network | "eth1" => network["eth0"]},
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

  test "reject malformed text, improper DNS lists, unknown data and credentials" do
    for network <- [nil, [], %{}, Map.put(Config.defaults()["network"], "password", "secret")] do
      assert {:error, _} = Config.validate_network(network)
    end

    assert {:error, _} = Config.validate_address(%{@static | "static_ip" => <<255>>})

    for dns <- [["1.1.1.1" | :invalid], ["1.1.1.1", "8.8.8.8", "9.9.9.9", "8.8.4.4"], [<<255>>]] do
      assert {:error, _} = Config.validate_address(Map.put(@static, "nameservers", dns))
    end
  end
end
