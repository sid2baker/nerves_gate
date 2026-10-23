defmodule NervesGate.Network.CellularTest do
  use ExUnit.Case, async: false
  alias NervesGate.Config
  alias NervesGate.Network.{Cellular, Policy}

  @profile %{
    interface: "wwan0",
    config: %{type: VintageNetECM, vintage_net_ecm: %{at_tty: "ttyUSB2"}}
  }
  @network %{
    "mode" => "ports",
    "eth0" => nil,
    "eth1" => nil,
    "internet" => %{"mode" => "cellular", "apn" => "internet.example"}
  }

  setup do
    previous = Application.fetch_env(:nerves_gate, :cellular)
    Application.put_env(:nerves_gate, :cellular, @profile)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:nerves_gate, :cellular, value)
        :error -> Application.delete_env(:nerves_gate, :cellular)
      end
    end)
  end

  test "ECM uses the selected APN, fixed AT port, context 1 and DHCP" do
    assert Cellular.profile() == @profile
    assert {:ok, [{"wwan0", config}]} = Cellular.configurations(@network)
    normalized = VintageNetECM.normalize(config)
    assert normalized.ipv4 == %{method: :dhcp}

    assert normalized.vintage_net_ecm == %{
             at_tty: "ttyUSB2",
             context_id: 1,
             modem: VintageNetECM.Modem.Quectel,
             service_providers: [%{apn: "internet.example"}]
           }

    raw = VintageNetECM.to_raw_config("wwan0", config, [])
    assert raw.required_ifnames == ["wwan0"]
    assert raw.source_config.type == VintageNetECM
  end

  test "Ethernet-only disables the modem without changing the recovery interface" do
    network = Map.put(@network, "internet", %{"mode" => "ethernet"})

    assert Cellular.configurations(network) ==
             {:ok, [{"wwan0", %{type: VintageNet.Technology.Null}}]}
  end

  test "platforms without a modem profile reject cellular before configuring interfaces" do
    Application.put_env(:nerves_gate, :cellular, nil)
    assert Cellular.profile() == nil
    assert Cellular.configurations(@network) == {:error, :cellular_unsupported}
    assert Cellular.configurations(%{"mode" => "unconfigured"}) == {:ok, []}
  end

  test "profiles cannot assign a recovery, LAN or VPN interface to the modem" do
    for name <- ["usb0", "eth0", "br0", "tailscale0", "wwan0;reboot", "wwan"] do
      Application.put_env(:nerves_gate, :cellular, %{@profile | interface: name})
      assert Cellular.profile() == nil
      assert Cellular.configurations(@network) == {:error, :cellular_unsupported}
    end
  end

  test "empty APN requests the network default through the ECM controller" do
    network = put_in(@network, ["internet", "apn"], "")
    assert Config.validate_network(network) == {:ok, network}
    assert {:ok, [{"wwan0", config}]} = Cellular.configurations(network)
    assert VintageNetECM.normalize(config).vintage_net_ecm.service_providers == [%{apn: ""}]
    raw = VintageNetECM.to_raw_config("wwan0", config, [])

    assert {VintageNetECM.ATController, options} =
             Enum.find(raw.child_specs, &match?({VintageNetECM.ATController, _}, &1))

    assert options[:apn] == ""
    assert options[:context_id] == 1
    assert raw.source_config.vintage_net_ecm.service_providers == [%{apn: ""}]
  end

  test "backend admission requires actual modem presence, not just a firmware profile" do
    supported = %{cellular_supported: true, cellular: %{present: true}}
    assert Policy.supported(supported, @network) == :ok

    for cellular <- [nil, %{present: false}] do
      assert Policy.supported(%{supported | cellular: cellular}, @network) ==
               {:error, :cellular_missing}
    end

    missing = %{supported | cellular: nil}
    assert Policy.supported(missing, @network, @network) == :ok
    changed_apn = put_in(@network, ["internet", "apn"], "different.apn")
    assert Policy.supported(missing, changed_apn, @network) == {:error, :cellular_missing}
    assert Policy.supported(nil, @network) == {:error, :cellular_unsupported}
    ethernet = Map.put(@network, "internet", %{"mode" => "ethernet"})
    assert Policy.supported(%{supported | cellular: nil}, ethernet) == :ok
  end

  test "backend admission rejects malformed, oversized and command-bearing APNs" do
    assert {:ok, @network} = Config.validate_network(@network)

    for apn <- [nil, "internet\"\rAT+CFUN=0", "has space", String.duplicate("a", 101)] do
      assert {:error, message} =
               Config.validate_network(put_in(@network, ["internet", "apn"], apn))

      assert message =~ "APN"
    end
  end
end
