defmodule NervesGate.CellularTest do
  use ExUnit.Case, async: false
  alias NervesGate.Config
  alias NervesGate.Network.{Cellular, Vintage}
  @moduletag :tmp_dir

  # Only normalize persisted data. Never start a real modem, VintageNet or networking.
  defmodule Technology do
    def normalize(config), do: config
  end

  @profile %{interface: "wwan0", config: %{type: Technology, vintage_net_qmi: %{}}}
  @network %{
    "mode" => "ports",
    "eth0" => nil,
    "eth1" => nil,
    "internet" => %{"mode" => "cellular", "apn" => "internet.example"}
  }

  setup %{tmp_dir: dir} do
    settings = [
      {:nerves_gate, :cellular, @profile},
      {:vintage_net, :persistence, VintageNet.Persistence.FlatFile},
      {:vintage_net, :persistence_dir, Path.join(dir, "vintage")},
      {:vintage_net, :persistence_secret, "test-secret-1234"}
    ]

    old = for {app, key, _} <- settings, do: {app, key, Application.fetch_env(app, key)}
    for {app, key, value} <- settings, do: Application.put_env(app, key, value)

    on_exit(fn ->
      for {app, key, value} <- old do
        case value do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    :ok
  end

  test "qualified profile produces standard APN configuration and Ethernet-only disables the modem" do
    assert {:ok, [{"wwan0", config}]} = Cellular.configurations(@network)

    assert config == %{
             type: Technology,
             vintage_net_qmi: %{service_providers: [%{apn: "internet.example"}]}
           }

    assert Cellular.configurations(Map.delete(@network, "internet")) ==
             {:ok, [{"wwan0", %{type: VintageNet.Technology.Null}}]}

    refute Process.whereis(VintageNet.Supervisor)
  end

  test "unidentified hardware and recovery-interface collisions are rejected" do
    for profile <- [
          nil,
          %{@profile | interface: "usb0"},
          %{@profile | interface: "eth0"},
          %{@profile | interface: "br0"},
          %{@profile | interface: "wwan0; echo bad"},
          %{@profile | config: %{type: NotInstalled, vintage_net_qmi: %{}}}
        ] do
      Application.put_env(:nerves_gate, :cellular, profile)
      assert Cellular.profile() == nil
      assert Cellular.configurations(@network) == {:error, :cellular_unsupported}
      assert Cellular.configurations(Config.defaults()["network"]) == {:ok, []}
    end
  end

  test "mode and APN round-trip in VintageNet without a second store, preserving USB" do
    assert :ok = VintageNet.Persistence.call(:save, ["usb0", %{independent: true}])
    assert :ok = Vintage.save(@network, nil)
    assert Vintage.load(nil) == {:ok, Config.from_network(@network)}

    assert {:ok, %{vintage_net_qmi: %{service_providers: [%{apn: "internet.example"}]}}} =
             VintageNet.Persistence.call(:load, ["wwan0"])

    assert VintageNet.Persistence.call(:load, ["usb0"]) == {:ok, %{independent: true}}

    ethernet = Map.delete(@network, "internet")
    assert :ok = Vintage.save(ethernet, nil)
    assert Vintage.load(nil) == {:ok, Config.from_network(ethernet)}

    assert {:ok, %{type: VintageNet.Technology.Null}} =
             VintageNet.Persistence.call(:load, ["wwan0"])

    refute Process.whereis(VintageNet.Supervisor)
  end
end
