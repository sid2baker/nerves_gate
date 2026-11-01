defmodule NervesGate.NetworkVintageTest do
  use ExUnit.Case, async: false
  alias NervesGate.Config
  alias NervesGate.Network.Vintage

  @modem %{
    interface: "wwan0",
    config: %{
      type: VintageNetECM,
      vintage_net_ecm: %{at_tty: "ttyUSB2", modem: NervesGate.Cellular.Modem}
    }
  }

  setup do
    root = Path.join(System.tmp_dir!(), "network-vintage-#{System.unique_integer([:positive])}")

    settings = [
      {:vintage_net, :persistence_dir, root},
      {:vintage_net, :persistence, VintageNet.Persistence.FlatFile},
      {:vintage_net, :persistence_secret, <<0::128>>}
    ]

    previous =
      Enum.map(settings, fn {app, key, _} -> {app, key, Application.fetch_env(app, key)} end)

    Enum.each(settings, fn {app, key, value} -> Application.put_env(app, key, value) end)
    board = Application.fetch_env!(:nerves_gate, :board)

    on_exit(fn ->
      Enum.each(previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)

      Application.put_env(:nerves_gate, :board, board)
      File.rm_rf!(root)
    end)

    %{root: root, board: board}
  end

  test "an uncertain commit blocks further admission" do
    assert {:error, %{code: "network_commit_unknown"}} =
             NervesGate.Network.Policy.available(%{config: %{}, commit_unknown: true, error: nil})
  end

  test "no saved configs is the factory state; reading writes nothing", %{root: root} do
    assert Vintage.load() == {:ok, Config.defaults()}
    refute File.exists?(root)
    assert {:error, _} = Vintage.save(%{"mode" => "unconfigured"})
    refute File.exists?(root)
  end

  test "settings are plain VintageNet interface configs, with no extra metadata", %{root: root} do
    assert :ok = Vintage.save(ports())
    assert Enum.sort(File.ls!(root)) == Enum.sort(NervesGate.Board.ethernet())

    for {name, config} <- Vintage.configurations(ports()) do
      assert {:ok, saved} = VintageNet.Persistence.call(:load, [name])
      assert saved == config.type.normalize(config)
      assert saved |> Map.keys() |> Enum.all?(&(&1 in [:type, :ipv4, :nerves_gate_disabled]))
    end
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

  test "cellular policy comes from the modem's own config", %{board: board} do
    Application.put_env(:nerves_gate, :board, Map.put(board, :cellular, @modem))
    cellular = %{"mode" => "cellular", "apn" => "internet.example"}

    for network <- [
          ports(),
          Map.put(ports(), "internet", %{cellular | "mode" => "backup"}),
          ports() |> Map.put("eth0", nil) |> Map.put("internet", cellular)
        ] do
      assert :ok = Vintage.save(network)
      assert Vintage.load() == {:ok, Config.from_network(network)}
      assert Vintage.check_saved_cellular() == :ok
    end
  end

  test "a modem config this board would not write blocks startup and is kept", %{
    root: root,
    board: board
  } do
    Application.put_env(:nerves_gate, :board, Map.put(board, :cellular, @modem))
    assert :ok = Vintage.save(ports())
    {:ok, saved} = VintageNet.Persistence.call(:load, ["wwan0"])
    unsafe = put_in(saved, [:vintage_net_ecm, :modem], VintageNetECM.Modem.Quectel)
    assert :ok = VintageNet.Persistence.call(:save, ["wwan0", unsafe])
    before = files(root)
    assert {:error, _} = Vintage.check_saved_cellular()
    assert {:error, _} = Vintage.load()
    assert files(root) == before
  end

  test "invalid writes preserve saved configs", %{root: root} do
    assert :ok = Vintage.save(ports())
    before = files(root)
    assert {:error, _} = Vintage.save(%{"mode" => "shared"})
    assert files(root) == before
  end

  test "corrupt, partial and foreign configs are rejected and preserved", %{root: root} do
    for damage <- [
          &File.write!(Path.join(&1, "eth0"), "corrupt"),
          &File.rm!(Path.join(&1, "eth1")),
          fn _ ->
            VintageNet.Persistence.call(:save, [
              "eth1",
              %{type: NervesGate.Network.LAN, ipv4: %{method: :dhcp}}
            ])
          end,
          fn _ ->
            VintageNet.Persistence.call(:save, [
              "eth0",
              %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}
            ])
          end
        ] do
      assert :ok = Vintage.save(ports())
      damage.(root)
      before = files(root)
      assert {:error, message} = Vintage.load()
      assert message =~ "Settings were not changed"
      assert files(root) == before
    end
  end

  test "write failures are uncertain, including a partially saved set", %{root: root} do
    assert :ok = Vintage.save(ports())
    File.rm!(Path.join(root, "eth1"))
    File.mkdir!(Path.join(root, "eth1"))
    assert {:error, :network_commit_unknown} = Vintage.save(Map.put(ports(), "eth1", nil))
  end

  defp ports do
    %{
      "mode" => "ports",
      "eth0" => %{"role" => "internet", "address" => Config.address_defaults()},
      "eth1" => %{"role" => "plugin", "address" => nil}
    }
  end

  defp files(root), do: Map.new(File.ls!(root), &{&1, File.read!(Path.join(root, &1))})
end
