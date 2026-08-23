defmodule NervesGate.StoreTest do
  use ExUnit.Case, async: true

  alias NervesGate.Store
  alias NervesGate.TestScenario

  setup do
    root = TestScenario.temporary_root(:store)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "storage initialization is private and writable", %{root: root} do
    assert :ok = Store.initialize(root)
    assert File.stat!(root).mode |> Bitwise.band(0o777) == 0o700
  end

  test "JSON writes are atomic, readable, and human-readable", %{root: root} do
    path = Store.settings_path("a", root)
    value = %{"version" => 1, "name" => "gateway"}

    assert :ok = Store.write_json(path, value)
    assert {:ok, ^value} = Store.read_json(path, &{:ok, &1}, nil)
    assert File.read!(path) =~ "\n  \"name\""
    assert Path.wildcard(path <> ".tmp-*") == []
  end

  test "corrupt JSON is quarantined", %{root: root} do
    path = Store.settings_path("a", root)
    File.mkdir_p!(root)
    File.write!(path, "not-json")

    assert {:error, {:corrupt, "settings-a.json", _reason}} =
             Store.read_json(path, &{:ok, &1}, nil)

    assert [_quarantined] = Path.wildcard(path <> ".corrupt-*")
  end

  test "legacy per-subsystem settings are removed", %{root: root} do
    File.mkdir_p!(root)

    for name <- ~w(setup.json network.json cluster.json device.json settings-change.json) do
      File.write!(Path.join(root, name), "legacy")
    end

    assert :ok = Store.clear_legacy_settings(root)
    assert Path.wildcard(Path.join(root, "*.json")) == []
  end

  test "candidate promotion replaces only the selected slot", %{root: root} do
    active = %{"slot" => "old"}
    candidate = %{"slot" => "candidate"}
    other = %{"slot" => "other"}

    :ok = Store.write_json(Store.settings_path("a", root), active)
    :ok = Store.write_json(Store.settings_path("b", root), other)
    :ok = Store.write_json(Store.candidate_path(root), candidate)

    assert :ok = Store.promote_candidate("a", root)
    assert {:ok, ^candidate} = Store.read_json(Store.settings_path("a", root), &{:ok, &1}, nil)
    assert {:ok, ^other} = Store.read_json(Store.settings_path("b", root), &{:ok, &1}, nil)
    refute File.exists?(Store.candidate_path(root))
  end
end
