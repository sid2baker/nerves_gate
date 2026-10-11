defmodule NervesGate.VintagePersistenceTest do
  use ExUnit.Case, async: false
  alias NervesGate.Config
  alias NervesGate.Network.{LAN, Vintage}
  @moduletag :tmp_dir
  @static %{
    "ip_method" => "static",
    "static_ip" => "192.168.40.2",
    "subnet_mask" => "255.255.255.0",
    "gateway" => nil
  }
  @empty %{"mode" => "ports", "eth0" => nil, "eth1" => nil}

  setup %{tmp_dir: dir} do
    settings = [
      persistence: VintageNet.Persistence.FlatFile,
      persistence_dir: Path.join(dir, "vintage"),
      persistence_secret: "test-secret-1234"
    ]

    old = Enum.map(settings, fn {key, _} -> {key, Application.fetch_env(:vintage_net, key)} end)
    for {key, value} <- settings, do: Application.put_env(:vintage_net, key, value)

    on_exit(fn ->
      for {key, value} <- old do
        case value do
          {:ok, value} -> Application.put_env(:vintage_net, key, value)
          :error -> Application.delete_env(:vintage_net, key)
        end
      end
    end)

    %{dir: settings[:persistence_dir]}
  end

  test "all modes and roles round-trip actual normalized VintageNet files without starting networking",
       ctx do
    wan = %{"role" => "internet", "address" => Config.address_defaults()}
    equipment = %{"role" => "equipment", "address" => @static}

    manual =
      Map.merge(@static, %{"gateway" => "192.168.40.1", "nameservers" => ["1.1.1.1", "9.9.9.9"]})

    networks = [
      Config.defaults()["network"],
      @empty,
      %{"mode" => "shared", "equipment" => Config.address_defaults()},
      %{"mode" => "shared", "equipment" => manual},
      %{
        "mode" => "ports",
        "eth0" => %{"role" => "internet", "address" => NervesGate.Config.address_defaults()},
        "eth1" => %{"role" => "equipment", "address" => @static}
      },
      %{
        "mode" => "ports",
        "eth1" => %{"role" => "internet", "address" => NervesGate.Config.address_defaults()},
        "eth0" => %{"role" => "equipment", "address" => @static}
      },
      Map.put(@empty, "eth0", wan),
      Map.put(@empty, "eth1", equipment),
      %{"mode" => "ports", "eth0" => equipment, "eth1" => %{wan | "address" => manual}}
    ]

    refute Process.whereis(VintageNet.Supervisor)
    assert Vintage.load(nil) == {:ok, Config.defaults()}

    for network <- networks do
      configs =
        Map.new(Vintage.configurations(network), fn {name, config} ->
          {name, LAN.normalize(config)}
        end)

      assert Vintage.from_configurations(configs) == {:ok, network}
      assert :ok = Vintage.save(network, nil)
      assert Vintage.load(nil) == {:ok, Config.from_network(network)}

      for {name, config} <- configs do
        assert VintageNet.Persistence.call(:load, [name]) == {:ok, config}
      end
    end

    assert Enum.sort(File.ls!(ctx.dir)) == ["br0", "eth0", "eth1"]
    refute Process.whereis(VintageNet.Supervisor)
  end

  test "confirmation writes even unchanged settings and never touches saved USB", ctx do
    assert :ok = VintageNet.Persistence.call(:save, ["usb0", %{independent: true}])
    assert :ok = Vintage.save(@empty, nil)
    before = File.read!(Path.join(ctx.dir, "br0"))
    assert :ok = Vintage.save(@empty, nil)
    # FlatFile uses a new IV each time: confirmation really wrote the file.
    refute File.read!(Path.join(ctx.dir, "br0")) == before
    assert VintageNet.Persistence.call(:load, ["usb0"]) == {:ok, %{independent: true}}
  end

  test "save errors are returned; multi-interface persistence is deliberately not transactional",
       ctx do
    assert :ok = Vintage.save(@empty, nil)
    eth1 = Path.join(ctx.dir, "eth1")
    File.rm!(eth1)
    File.mkdir!(eth1)

    network =
      Map.put(@empty, "eth0", %{"role" => "internet", "address" => Config.address_defaults()})

    assert {:error, :eisdir} = Vintage.save(network, nil)
    # Earlier saves may have succeeded. Do not add a journal to undo them.
    assert {:ok, %{ipv4: %{method: :dhcp}}} = VintageNet.Persistence.call(:load, ["eth0"])
  end

  test "corrupt files fail closed and are not overwritten during load", ctx do
    assert :ok = Vintage.save(@empty, nil)
    path = Path.join(ctx.dir, "eth0")
    File.write!(path, "broken")
    assert {:error, :corrupt} = Vintage.load(nil)
    assert File.read!(path) == "broken"
  end

  test "saved settings without a recognized mode fail closed" do
    assert :ok = VintageNet.Persistence.call(:save, ["br0", %{nerves_gate_mode: "unknown"}])
    assert {:error, _} = Vintage.load(nil)
  end
end
