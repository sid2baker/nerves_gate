defmodule NervesGate.StorageTest do
  use ExUnit.Case, async: true

  alias NervesGate.Storage
  alias NervesGate.TestScenario

  setup do
    root = TestScenario.temporary_root(:storage)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "builds paths under the configured data root", %{root: root} do
    assert Storage.path(["tailscale", "state"], root) == Path.join(root, "tailscale/state")
  end

  test "initialization is private and writable", %{root: root} do
    assert :ok = Storage.initialize(root)
    assert File.stat!(root).mode |> Bitwise.band(0o777) == 0o700
  end

  test "JSON writes are atomic, readable, and human-readable", %{root: root} do
    path = Storage.path("document.json", root)
    value = %{"version" => 1, "name" => "gateway"}

    assert :ok = Storage.write_json(path, value)
    assert {:ok, ^value} = Storage.read_json(path, &{:ok, &1}, nil)
    assert File.read!(path) =~ "\n  \"name\""
    assert Path.wildcard(path <> ".tmp-*") == []
  end

  test "invalid JSON is reported without imposing a domain recovery policy", %{root: root} do
    path = Storage.path("document.json", root)
    File.mkdir_p!(root)
    File.write!(path, "not-json")

    assert {:error, {:invalid, _reason}} = Storage.read_json(path, &{:ok, &1}, nil)
    assert File.exists?(path)
  end

  test "replacement is restricted to one directory", %{root: root} do
    source = Storage.path("candidate", root)
    destination = Storage.path("accepted", root)
    assert :ok = Storage.write(source, "candidate")

    assert :ok = Storage.replace(source, destination)
    assert File.read!(destination) == "candidate"
    refute File.exists?(source)

    assert {:error, :cross_device_replace} =
             Storage.replace(destination, Storage.path(["other", "accepted"], root))
  end
end
