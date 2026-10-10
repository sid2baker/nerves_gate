defmodule NervesGate.LANTest do
  use ExUnit.Case, async: true
  alias NervesGate.Network.{LAN, Vintage}

  test "both Ethernet members have no IP or DHCP server and missing members don't block br0" do
    configs =
      Vintage.configurations(%{
        "mode" => "shared",
        "equipment" => NervesGate.Config.address_defaults()
      })

    assert Enum.map(configs, &elem(&1, 0)) == ["eth0", "eth1", "br0"]

    for {name, config} <- configs do
      refute Map.has_key?(config, :dhcpd)
      raw = LAN.to_raw_config(name, config, [])

      if name == "br0" do
        assert raw.required_ifnames == []
        assert config.ipv4.method == :dhcp
        assert config.vintage_net_bridge.interfaces == ["eth0", "eth1"]
        assert Enum.any?(raw.child_specs, &match?({VintageNetBridge.Server, _}, &1))
        refute {:run, "brctl", ["delbr", "br0"]} in raw.down_cmds
        refute {:run, "ip", ["link", "set", "br0", "down"]} in raw.down_cmds
        assert hd(raw.up_cmds) == {:fun, LAN, :ensure_bridge, []}
      else
        assert config.ipv4.method == :disabled
        assert raw.required_ifnames == [name]
        assert raw.child_specs == []
        assert {:fun, LAN, :disable_member_ipv6, [name]} in raw.up_cmds
      end
    end
  end

  test "static addressing and optional default route are only on the bridge" do
    network = %{
      "ip_method" => "static",
      "static_ip" => "10.0.1.10",
      "subnet_mask" => "255.255.255.0",
      "gateway" => nil
    }

    config = Map.new(Vintage.configurations(%{"mode" => "shared", "equipment" => network}))["br0"]
    raw = LAN.to_raw_config("br0", config, [])
    assert raw.source_config.ipv4.address == {10, 0, 1, 10}
    refute Map.has_key?(raw.source_config.ipv4, :gateway)

    config =
      Map.new(
        Vintage.configurations(%{
          "mode" => "shared",
          "equipment" => %{network | "gateway" => "10.0.1.1"}
        })
      )["br0"]

    assert LAN.normalize(config).ipv4.gateway == {10, 0, 1, 1}
  end

  test "new defaults never bridge, serve DHCP, or configure USB" do
    configs = NervesGate.Network.Vintage.configurations(NervesGate.Config.defaults()["network"])
    assert Enum.sort(Enum.map(configs, &elem(&1, 0))) == ["br0", "eth0", "eth1"]

    for {name, config} <- configs do
      assert config.ipv4.method ==
               (if name == "br0" do
                  :disabled
                else
                  :dhcp
                end)

      refute Map.has_key?(config, :dhcpd)
    end

    raw = NervesGate.Network.LAN.to_raw_config("br0", Map.new(configs)["br0"], [])
    assert {:fun, NervesGate.Network.LAN, :sync_members, [[]]} in raw.up_cmds
  end

  test "DHCP teardown clears routes before removing the source address" do
    for name <- ["eth0", "eth1", "br0"] do
      config = %{type: LAN, ipv4: %{method: :dhcp}}

      config =
        if name == "br0" do
          Map.put(config, :vintage_net_bridge, %{interfaces: ["eth0", "eth1"]})
        else
          config
        end

      raw = LAN.to_raw_config(name, config, [])
      assert hd(raw.down_cmds) == {:fun, VintageNet.RouteManager, :clear_route, [name]}

      assert Enum.any?(tl(raw.down_cmds), fn cmd ->
               match?({:run_ignore_errors, "ip", ["addr", "flush" | _]}, cmd)
             end)
    end
  end

  test "either port can provide Internet without a route or DHCP server on equipment" do
    for internet <- ["eth0", "eth1"] do
      network = %{
        "mode" => "ethernet",
        "internet_port" => internet,
        "equipment" => %{
          "ip_method" => "static",
          "static_ip" => "10.0.1.2",
          "subnet_mask" => "255.255.255.0",
          "gateway" => nil
        }
      }

      configs = Map.new(Vintage.configurations(network))
      assert configs[internet].ipv4 == %{method: :dhcp}
      assert configs["br0"].vintage_net_bridge.interfaces == []
      equipment = configs[NervesGate.Config.equipment_port(network)]
      assert equipment.ipv4.method == :static
      refute Map.has_key?(equipment.ipv4, :gateway)
      refute Map.has_key?(equipment, :dhcpd)
      refute Map.has_key?(configs, "usb0")
    end
  end
end
