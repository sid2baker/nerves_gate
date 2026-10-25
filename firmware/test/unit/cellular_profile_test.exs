defmodule NervesGate.Cellular.ProfileTest do
  use ExUnit.Case, async: false
  alias NervesGate.Config
  alias NervesGate.Network.Policy

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
    previous = Application.fetch_env(:nerves_gate, :board)
    put_profile(@profile)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:nerves_gate, :board, value)
        :error -> Application.delete_env(:nerves_gate, :board)
      end
    end)
  end

  test "saved drivers are checked before any controller can open the UART" do
    assert :ok = NervesGate.Cellular.Profile.check_saved(%{type: VintageNet.Technology.Null})
    config = %{type: VintageNetECM, vintage_net_ecm: %{modem: NervesGate.Cellular.Modem}}
    assert :ok = NervesGate.Cellular.Profile.check_saved(config)

    stale = put_in(config.vintage_net_ecm.modem, NervesGate.MissingCellularModem)

    assert {:error, %{code: "cellular_saved_config_unavailable"}} =
             NervesGate.Cellular.Profile.check_saved(stale)

    assert stale.vintage_net_ecm.modem == NervesGate.MissingCellularModem
  end

  test "ECM uses the selected APN, fixed AT port, context 1 and DHCP" do
    assert NervesGate.Cellular.Profile.get() == @profile
    assert {:ok, [{"wwan0", config}]} = NervesGate.Cellular.Profile.configurations(@network)
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

  test "EC100's authentication hook runs in the standard ECM controller, not interface config" do
    put_profile(put_in(@profile, [:config, :vintage_net_ecm, :modem], NervesGate.Cellular.Modem))
    assert {:ok, [{"wwan0", config}]} = NervesGate.Cellular.Profile.configurations(@network)
    raw = VintageNetECM.to_raw_config("wwan0", config, [])

    assert {VintageNetECM.ATController, options} =
             Enum.find(raw.child_specs, &match?({VintageNetECM.ATController, _}, &1))

    assert options[:modem] == NervesGate.Cellular.Modem
    assert raw.source_config.vintage_net_ecm.service_providers == [%{apn: "internet.example"}]
    refute Map.has_key?(raw.source_config.vintage_net_ecm, :password)
    refute Map.has_key?(raw.source_config.vintage_net_ecm, :username)
  end

  test "EC100 keeps one SIM controller without IP, DHCP, routes or a data session" do
    profile = put_in(@profile, [:config, :vintage_net_ecm, :modem], NervesGate.Cellular.Modem)
    put_profile(profile)
    network = Map.put(@network, "internet", %{"mode" => "ethernet"})
    assert {:ok, [{"wwan0", config}]} = NervesGate.Cellular.Profile.configurations(network)
    assert config.ipv4 == %{method: :disabled}
    assert config.vintage_net_ecm.setup_only
    assert NervesGate.Cellular.Modem.connection_mode(config) == :setup_only
    raw = VintageNetECM.to_raw_config("wwan0", config, [])
    assert [_] = Enum.filter(raw.child_specs, &match?({VintageNetECM.ATController, _}, &1))
    assert raw.source_config.ipv4.method == :disabled
    assert {:ok, [{"wwan0", data}]} = NervesGate.Cellular.Profile.configurations(@network)
    assert NervesGate.Cellular.Modem.connection_mode(data) == {:data, "internet.example"}
    assert NervesGate.Cellular.Modem.connection_mode(@profile.config) == :unsupported
  end

  test "generic profiles still disable the modem without changing the recovery interface" do
    network = Map.put(@network, "internet", %{"mode" => "ethernet"})

    assert NervesGate.Cellular.Profile.configurations(network) ==
             {:ok, [{"wwan0", %{type: VintageNet.Technology.Null}}]}
  end

  test "platforms without a modem profile reject cellular before configuring interfaces" do
    put_profile(nil)
    assert NervesGate.Cellular.Profile.get() == nil

    assert NervesGate.Cellular.Profile.configurations(@network) ==
             {:error,
              %{
                code: "cellular_unsupported",
                message:
                  "Cellular setup needs a qualified modem driver and dedicated interface in this firmware."
              }}

    assert NervesGate.Cellular.Profile.configurations(%{"mode" => "unconfigured"}) == {:ok, []}
  end

  test "profiles cannot assign a recovery, LAN or VPN interface to the modem" do
    for name <- ["usb0", "eth0", "br0", "tailscale0", "wwan0;reboot", "wwan"] do
      put_profile(%{@profile | interface: name})
      assert NervesGate.Cellular.Profile.get() == nil

      assert NervesGate.Cellular.Profile.configurations(@network) ==
               {:error,
                %{
                  code: "cellular_unsupported",
                  message:
                    "Cellular setup needs a qualified modem driver and dedicated interface in this firmware."
                }}
    end
  end

  test "empty APN requests the network default through the ECM controller" do
    network = put_in(@network, ["internet", "apn"], "")
    assert Config.validate_network(network) == {:ok, network}
    assert {:ok, [{"wwan0", config}]} = NervesGate.Cellular.Profile.configurations(network)
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
               {:error,
                %{
                  code: "cellular_missing",
                  message:
                    "The configured cellular interface is not detected. Check modem power and USB enumeration."
                }}
    end

    missing = %{supported | cellular: nil}
    assert Policy.supported(missing, @network, @network) == :ok
    changed_apn = put_in(@network, ["internet", "apn"], "different.apn")

    assert Policy.supported(missing, changed_apn, @network) ==
             {:error,
              %{
                code: "cellular_missing",
                message:
                  "The configured cellular interface is not detected. Check modem power and USB enumeration."
              }}

    assert Policy.supported(nil, @network) ==
             {:error,
              %{
                code: "cellular_unsupported",
                message:
                  "Cellular setup needs a qualified modem driver and dedicated interface in this firmware."
              }}

    ethernet = Map.put(@network, "internet", %{"mode" => "ethernet"})
    assert Policy.supported(%{supported | cellular: nil}, ethernet) == :ok
  end

  defp put_profile(profile) do
    board = Application.get_env(:nerves_gate, :board, %{})
    Application.put_env(:nerves_gate, :board, Map.put(board, :cellular, profile))
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
