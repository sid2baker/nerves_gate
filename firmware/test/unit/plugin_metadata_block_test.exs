defmodule NervesGate.PluginMetadataBlockTest do
  use ExUnit.Case, async: false
  alias NervesGate.{Plugins, Settings}
  alias NervesGate.Plugins.Metadata
  @moduletag :tmp_dir
  @key ["plugins", "entries"]
  @saved %{"old_entry" => %{enabled: true}}

  setup %{tmp_dir: dir} do
    # Plugins relies on the services before it in the supervision order.
    start_supervised!({Settings, path: dir})
    :ok = Settings.put(@key, @saved)
    start_supervised!({PropertyTable, name: NervesGate.Properties})
    start_supervised!({Task.Supervisor, name: NervesGate.PluginTasks})
    %{pid: start_supervised!(Plugins)}
  end

  test "unsupported metadata blocks app management without taking its controller down", %{
    pid: pid
  } do
    assert {:error, :invalid_app_metadata} = Plugins.list()
    assert {:error, :plugins_blocked} = Plugins.start(:old_entry)
    assert {:error, :plugins_blocked} = Plugins.install("/missing.ez")
    assert Process.alive?(pid)
    assert Settings.get(@key) == @saved
  end

  test "oversized catalogs are rejected without replacing existing metadata" do
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

    assert Metadata.valid?(entries)
    assert :erlang.external_size(entries) > 4 * 1024 * 1024
    assert {:error, :invalid_app_metadata} = Metadata.save(entries)
    assert Settings.get(@key) == @saved
  end

  test "unreadable ownership cannot make formatting safe" do
    assert {:error, %{code: "plugins_installed"}} =
             GenServer.call(Plugins, {:storage_setup, :format, "card", :erase_all_data})

    assert Settings.get(@key) == @saved
  end
end
