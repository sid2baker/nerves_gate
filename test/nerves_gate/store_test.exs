defmodule NervesGate.StoreTest do
  use ExUnit.Case, async: true

  alias NervesGate.AtomicFile
  alias NervesGate.Store
  alias NervesGate.TestScenario

  test "first boot starts at the Internet step" do
    root = TestScenario.temporary_root(:first_boot)
    assert :ok = Store.initialize(root)
    assert {:ok, %{"phase" => "internet", "version" => 1}} = Store.read_setup(root)
  end

  test "atomic replacement never leaves partial persisted data" do
    root = TestScenario.temporary_root(:atomic)
    path = Path.join(root, "value")

    assert :ok = AtomicFile.write(path, "old")
    assert :ok = AtomicFile.write(path, String.duplicate("new", 1_000))
    assert File.read!(path) == String.duplicate("new", 1_000)
    assert Path.wildcard(path <> ".tmp-*") == []
  end

  test "corrupt setup is quarantined instead of boot-looping" do
    root = TestScenario.temporary_root(:corrupt)
    assert :ok = Store.initialize(root)
    File.write!(Path.join(root, "setup.json"), "not-json")

    assert {:error, {:corrupt, "setup.json", _reason}} = Store.read_setup(root)
    assert [_quarantined] = Path.wildcard(Path.join(root, "setup.json.corrupt-*"))
    assert {:ok, %{"phase" => "internet"}} = Store.read_setup(root)
  end

  test "cluster configuration is human-readable and restricted to the owner" do
    root = TestScenario.temporary_root(:cluster_cookie)
    cookie = "Persistent_cookie-123"

    assert :ok = Store.initialize(root)
    assert :ok = Store.write_cluster(cookie, root)
    assert {:ok, ^cookie} = Store.read_cluster(root)

    path = Path.join(root, "cluster.json")
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Jason.decode!(File.read!(path)) == %{"version" => 1, "cookie" => cookie}
  end

  test "unwritable data path reports an error" do
    root = TestScenario.temporary_root(:unwritable)
    File.write!(root, "blocks-directory-creation")
    assert {:error, _reason} = Store.initialize(root)
  end

  test "all four setup phases and recovery are human-readable and resumable" do
    Enum.each([:internet, :tailscale, :cluster, :ready, :recovery], fn phase ->
      root = TestScenario.temporary_root("power_#{phase}")
      assert :ok = Store.initialize(root)
      assert :ok = Store.write_phase(phase, root)
      assert {:ok, %{"phase" => persisted}} = Store.read_setup(root)
      assert persisted == Atom.to_string(phase)
      assert File.read!(Path.join(root, "setup.json")) =~ "\n  \"phase\""
    end)
  end
end
