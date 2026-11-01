defmodule NervesGate.NetworkSettingsTest do
  use ExUnit.Case, async: false
  alias NervesGate.{Config, Network.Settings}

  setup do
    root = Path.join(System.tmp_dir!(), "network-settings-#{System.unique_integer([:positive])}")
    file = Path.join(root, "network.json")
    old_dir = Application.fetch_env(:vintage_net, :persistence_dir)
    old_file = Application.fetch_env(:nerves_gate, :network_settings)
    Application.put_env(:vintage_net, :persistence_dir, Path.join(root, "vintage_net"))
    Application.put_env(:nerves_gate, :network_settings, file)

    on_exit(fn ->
      restore(:vintage_net, :persistence_dir, old_dir)
      restore(:nerves_gate, :network_settings, old_file)
      File.rm_rf!(root)
    end)

    %{settings_file: file, root: root}
  end

  test "an uncertain commit blocks further admission" do
    # The latch remains authoritative even if restoration changes the displayed error.
    assert {:error, %{code: "network_commit_unknown"}} =
             NervesGate.Network.Policy.available(%{config: %{}, commit_unknown: true, error: nil})
  end

  test "factory settings are validated and never written on read", %{settings_file: file} do
    assert Settings.load() == {:ok, Config.defaults()}
    refute File.exists?(file)
  end

  test "confirmed settings round-trip as one private record, with no bridge", %{
    settings_file: file
  } do
    network = %{
      "mode" => "ports",
      "eth0" => %{"role" => "internet", "address" => Config.address_defaults()},
      "eth1" => %{"role" => "plugin", "address" => nil}
    }

    assert :ok = Settings.save(network)
    assert Settings.load() == {:ok, Config.from_network(network)}
    assert {:ok, %{mode: mode}} = File.stat(file)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert {:ok, %{"schema" => 1, "network" => ^network}} = file |> File.read!() |> Jason.decode()
    assert File.ls!(Path.dirname(file)) == ["network.json"]
  end

  test "invalid writes preserve the existing record", %{settings_file: file} do
    network = Config.defaults()["network"]
    assert :ok = Settings.save(network)
    before = File.read!(file)
    assert {:error, _} = Settings.save(%{"mode" => "shared"})
    assert File.read!(file) == before
  end

  test "corrupt, unknown schema and stale hardware records are preserved", %{
    settings_file: file,
    root: root
  } do
    File.mkdir_p!(root)

    for bytes <- [
          "broken",
          Jason.encode!(%{schema: 2, network: %{mode: "unconfigured"}}),
          Jason.encode!(%{schema: 1, network: %{mode: "ports", missing0: nil}})
        ] do
      File.write!(file, bytes)
      assert {:error, message} = Settings.load()
      assert message =~ "unsupported"
      assert File.read!(file) == bytes
    end
  end

  test "old interface files block reads and writes even alongside a new record", %{root: root} do
    assert :ok = Settings.save(Config.defaults()["network"])
    directory = Path.join(root, "vintage_net")
    File.mkdir_p!(directory)
    file = Path.join(directory, "br0")
    File.write!(file, "old saved configuration")
    assert {:error, message} = Settings.load()
    assert message =~ "Settings were not changed"
    assert {:error, ^message} = Settings.save(Config.defaults()["network"])
    assert File.read!(file) == "old saved configuration"
  end

  test "write failure preserves the previous confirmed record", %{settings_file: file} do
    assert :ok = Settings.save(Config.defaults()["network"])
    bytes = File.read!(file)
    Application.put_env(:nerves_gate, :network_settings, Path.join(file, "not-a-directory"))
    assert {:error, _} = Settings.save(Config.defaults()["network"])
    assert File.read!(file) == bytes
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)
end
