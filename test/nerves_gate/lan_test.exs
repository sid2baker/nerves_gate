defmodule NervesGate.LANTest do
  use ExUnit.Case, async: true
  alias NervesGate.Network.{LAN, Vintage}

  test "both Ethernet members have no IP or DHCP server and missing members don't block br0" do
    configs = Vintage.configurations(NervesGate.Config.defaults()["network"])
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

    config = Map.new(Vintage.configurations(network))["br0"]
    raw = LAN.to_raw_config("br0", config, [])
    assert raw.source_config.ipv4.address == {10, 0, 1, 10}
    refute Map.has_key?(raw.source_config.ipv4, :gateway)
    config = Map.new(Vintage.configurations(%{network | "gateway" => "10.0.1.1"}))["br0"]
    assert LAN.normalize(config).ipv4.gateway == {10, 0, 1, 1}
  end
end
