defmodule NervesGate.PluginMetadataBlockTest do
  use ExUnit.Case, async: false
  alias NervesGate.Plugins
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "apps.term")
    bytes = :erlang.term_to_binary(%{"old_entry" => %{enabled: true}})
    File.write!(path, bytes)
    previous = Application.get_env(:nerves_gate, :plugins_metadata)
    Application.put_env(:nerves_gate, :plugins_metadata, path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nerves_gate, :plugins_metadata, previous),
        else: Application.delete_env(:nerves_gate, :plugins_metadata)
    end)

    # Plugins relies on the services before it in the supervision order.
    start_supervised!({PropertyTable, name: NervesGate.Properties})
    start_supervised!({Task.Supervisor, name: NervesGate.PluginTasks})
    pid = start_supervised!(Plugins)
    %{pid: pid, path: path, bytes: bytes}
  end

  test "unsupported metadata blocks app management without taking its controller down", %{
    pid: pid,
    path: path,
    bytes: bytes
  } do
    assert {:error, :invalid_app_metadata} = Plugins.list()
    assert {:error, :plugins_blocked} = Plugins.start(:old_entry)
    assert {:error, :plugins_blocked} = Plugins.install("/missing.ez")
    assert Process.alive?(pid)
    assert File.read!(path) == bytes
  end

  test "oversized catalogs are rejected without replacing existing metadata", %{
    path: path,
    bytes: bytes
  } do
    modules = for n <- 1..10_000, do: "Elixir.CatalogFixture.Module#{n}"

    descriptor = %{
      sha256: String.duplicate("a", 64),
      source: :development,
      names: ["fixture"],
      modules: Enum.sort(modules)
    }

    artifacts = Map.new(1..20, &{"1.0.#{&1}", descriptor})

    entries = %{
      "fixture" => %{
        enabled: false,
        active_version: "1.0.1",
        previous_version: nil,
        generation: 0,
        artifacts: artifacts
      }
    }

    assert NervesGate.Plugins.Metadata.valid?(entries)
    assert byte_size(:erlang.term_to_binary(%{schema: 1, entries: entries})) > 4 * 1024 * 1024
    assert {:error, :invalid_app_metadata} = NervesGate.Plugins.Metadata.persist(path, entries)
    assert File.read!(path) == bytes
  end

  test "unreadable ownership cannot make formatting safe", %{path: path, bytes: bytes} do
    assert {:error, %{code: "plugins_installed"}} =
             GenServer.call(Plugins, {:storage_setup, :format, "card", :erase_all_data})

    assert File.read!(path) == bytes
  end
end
