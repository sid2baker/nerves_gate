defmodule NervesGate.NetworkVintageTest do
  use ExUnit.Case, async: false
  alias NervesGate.{Config, Settings}
  alias NervesGate.Network.Vintage

  @settings ["network", "settings"]
  @modem %{
    interface: "wwan0",
    config: %{
      type: VintageNetECM,
      vintage_net_ecm: %{at_tty: "ttyUSB2", modem: NervesGate.Cellular.Modem}
    }
  }

  setup do
    root = Path.join(System.tmp_dir!(), "network-vintage-#{System.unique_integer([:positive])}")
    start_supervised!({Settings, path: root})
    board = Application.fetch_env!(:nerves_gate, :board)

    on_exit(fn ->
      Application.put_env(:nerves_gate, :board, board)
      File.rm_rf!(root)
    end)

    %{root: root, board: board}
  end

  test "an uncertain commit blocks further admission" do
    assert {:error, %{code: "network_commit_unknown"}} =
             NervesGate.Network.Policy.available(%{config: %{}, commit_unknown: true, error: nil})
  end

  test "missing settings is the factory state; reading writes nothing", %{root: root} do
    assert Vintage.load() == {:ok, Config.defaults()}
    refute File.exists?(Settings.file(root))
    assert {:error, :factory_state_not_saved} = Vintage.save(%{"mode" => "unconfigured"})
    refute File.exists?(Settings.file(root))
  end

  test "one durable settings value contains user intent, not driver configuration", %{root: root} do
    assert :ok = Settings.put(["network", "local"], %{owner: :fixture})
    assert :ok = Vintage.save(ports())
    assert Settings.get(@settings) == ports()
    assert Settings.get(["network", "local"]) == %{owner: :fixture}
    stop_supervised!(Settings)
    start_supervised!({Settings, path: root})
    assert Vintage.load() == {:ok, Config.from_network(ports())}
    assert Settings.get(["network", "local"]) == %{owner: :fixture}
  end

  test "roles and addresses round-trip" do
    static = %{
      "ip_method" => "static",
      "static_ip" => "192.0.2.2",
      "subnet_mask" => "255.255.255.0",
      "gateway" => "192.0.2.1",
      "nameservers" => ["1.1.1.1", "8.8.8.8"]
    }

    for network <- [
          ports(),
          put_in(ports(), ["eth0", "address"], static),
          Map.put(ports(), "eth1", nil),
          %{ports() | "eth0" => nil}
        ] do
      assert :ok = Vintage.save(network)
      assert Vintage.load() == {:ok, Config.from_network(network)}
    end
  end

  test "cellular intent round-trips without modem internals", %{board: board} do
    Application.put_env(:nerves_gate, :board, Map.put(board, :cellular, @modem))
    cellular = %{"mode" => "cellular", "apn" => "internet.example"}

    for network <- [
          ports(),
          Map.put(ports(), "internet", %{cellular | "mode" => "backup"}),
          ports() |> Map.put("eth0", nil) |> Map.put("internet", cellular)
        ] do
      assert :ok = Vintage.save(network)
      assert Settings.get(@settings) == network
      assert Vintage.load() == {:ok, Config.from_network(network)}
    end
  end

  test "a firmware framing change uses the new profile without rewriting settings", %{
    root: root,
    board: board
  } do
    Application.put_env(:nerves_gate, :board, Map.put(board, :cellular, @modem))
    network = Map.put(ports(), "internet", %{"mode" => "backup", "apn" => "internet.example"})
    assert :ok = Vintage.save(network)
    before = File.read!(Settings.file(root))
    modem = put_in(@modem, [:config, :vintage_net_ecm, :intermediate_responses], ["> "])
    Application.put_env(:nerves_gate, :board, Map.put(board, :cellular, modem))

    assert {:ok, loaded} = Vintage.load()
    assert loaded == Config.from_network(network)

    assert {:ok, [{"wwan0", config}]} =
             NervesGate.Cellular.Profile.configurations(loaded["network"])

    raw = VintageNetECM.to_raw_config("wwan0", config, [])

    assert {VintageNetECM.AT.Channel, options} =
             Enum.find(raw.child_specs, &match?({VintageNetECM.AT.Channel, _}, &1))

    assert options[:intermediate_responses] == ["> "]
    assert File.read!(Settings.file(root)) == before
    assert Settings.get(@settings) == network
  end

  test "invalid writes preserve saved settings", %{root: root} do
    assert :ok = Vintage.save(ports())
    before = File.read!(Settings.file(root))
    assert {:error, _} = Vintage.save(%{"mode" => "shared"})
    assert File.read!(Settings.file(root)) == before
    assert Settings.get(@settings) == ports()
  end

  test "unsupported settings are rejected and preserved", %{root: root, board: board} do
    Application.put_env(:nerves_gate, :board, Map.put(board, :cellular, nil))

    for invalid <- [
          "corrupt",
          Map.delete(ports(), "eth1"),
          Map.put(ports(), "driver", VintageNetECM),
          put_in(ports(), ["eth0", "role"], "unknown"),
          Map.put(ports(), "internet", %{"mode" => "backup", "apn" => "internet.example"})
        ] do
      assert :ok = Settings.put(@settings, invalid)
      before = File.read!(Settings.file(root))
      assert {:error, message} = Vintage.load()
      assert message =~ "Settings were not changed"
      assert Settings.get(@settings) == invalid
      assert File.read!(Settings.file(root)) == before
    end
  end

  test "write failures are uncertain and do not leak into a later settings flush", %{root: root} do
    assert :ok = Vintage.save(ports())
    before = File.read!(Settings.file(root))
    blocker = Settings.file(root) <> ".tmp"
    File.mkdir!(blocker)
    assert {:error, :network_commit_unknown} = Vintage.save(Map.put(ports(), "eth1", nil))
    assert File.read!(Settings.file(root)) == before
    assert Settings.get(@settings) == ports()
    File.rmdir!(blocker)
    assert :ok = Settings.put(["unrelated"], true)
    stop_supervised!(Settings)
    start_supervised!({Settings, path: root})
    assert Vintage.load() == {:ok, Config.from_network(ports())}
  end

  defp ports do
    %{
      "mode" => "ports",
      "eth0" => %{"role" => "internet", "address" => Config.address_defaults()},
      "eth1" => %{"role" => "plugin", "address" => nil}
    }
  end
end
