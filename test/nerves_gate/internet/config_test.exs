defmodule NervesGate.Internet.ConfigTest do
  use ExUnit.Case, async: true

  alias NervesGate.Internet.Config

  test "supports DHCP and static IPv4 including subnet masks" do
    assert {:ok, %Config{method: :dhcp}} =
             Config.new(%{interface: "eth0", kind: "ethernet", method: "dhcp"})

    assert {:ok, %Config{prefix_length: 24, dns_secondary: "9.9.9.9"}} =
             Config.new(%{
               interface: "eth0",
               kind: "ethernet",
               method: "static",
               address: "192.0.2.10",
               subnet_mask: "255.255.255.0",
               gateway: "192.0.2.1",
               dns_primary: "1.1.1.1",
               dns_secondary: "9.9.9.9",
               search_domain: "field.example"
             })
  end

  test "supports Wi-Fi credentials and hidden networks without exposing passwords" do
    assert {:ok, config} =
             Config.new(%{
               interface: "wlan0",
               kind: "wifi",
               method: "dhcp",
               ssid: "field-network",
               security: "wpa_psk",
               password: "not-a-real-secret",
               hidden: "true"
             })

    assert config.hidden
    refute inspect(config) =~ "not-a-real-secret"
    refute Config.to_public(config) |> Map.has_key?(:password)
  end

  test "rejects wrong gateways and DNS values before application" do
    assert {:error, errors} =
             Config.new(%{
               interface: "eth0",
               kind: "ethernet",
               method: "static",
               address: "192.0.2.10",
               prefix_length: 24,
               gateway: "wrong",
               dns_primary: "also-wrong"
             })

    assert errors.gateway
    assert errors.dns_primary
  end
end
