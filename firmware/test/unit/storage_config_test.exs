defmodule NervesGate.StorageConfigTest do
  use ExUnit.Case, async: true
  alias NervesGate.Storage.Config
  @moduletag :tmp_dir

  defp file(dir, version), do: Path.join([dir, ".nerves_gate", "config", version <> ".term"])

  test "one opaque term per version, atomically replaced and restored", %{tmp_dir: dir} do
    assert Config.restore(dir, "0.3.0") == :not_found
    term = %{clients: [%{id: "a", port: 502}], servers: [], polling: {:ms, 500}}
    assert :ok = Config.save(dir, "0.3.0", term)
    assert {:ok, ^term} = Config.restore(dir, "0.3.0")
    assert :ok = Config.save(dir, "0.3.0", [:replaced])
    assert {:ok, [:replaced]} = Config.restore(dir, "0.3.0")
    assert {:ok, %{mode: mode}} = File.stat(file(dir, "0.3.0"))
    assert Bitwise.band(mode, 0o777) == 0o600
    assert Path.wildcard(Path.join([dir, ".nerves_gate", "config", "*.tmp"])) == []
  end

  test "versions are independent: no fallback, and other versions are preserved", %{
    tmp_dir: dir
  } do
    :ok = Config.save(dir, "0.3.0", :old)
    assert Config.restore(dir, "0.4.0") == :not_found
    :ok = Config.save(dir, "0.4.0", :new)
    assert :ok = Config.delete(dir, "0.4.0")
    assert Config.delete(dir, "0.4.0") == :not_found
    assert Config.restore(dir, "0.4.0") == :not_found
    assert {:ok, :old} = Config.restore(dir, "0.3.0")
  end

  test "unsafe, malformed and oversized files are reported and preserved", %{tmp_dir: dir} do
    :ok = Config.save(dir, "1.0.0", :ok)
    path = file(dir, "1.0.0")
    valid = :erlang.term_to_binary(%{a: 1})
    # A term naming an atom this VM has never seen.
    unknown_atom =
      <<131, 119, 20>> <> "never_seen_atom_" <> Base.encode16(:crypto.strong_rand_bytes(2))

    for bytes <- [
          "not a term",
          valid <> "trailing",
          :erlang.term_to_binary(:binary.copy("a", 4096), [:compressed]),
          unknown_atom,
          :binary.copy("x", 1_048_577)
        ] do
      File.write!(path, bytes)
      assert {:error, :invalid_configuration} = Config.restore(dir, "1.0.0")
      assert File.read!(path) == bytes
    end

    assert {:error, :configuration_too_large} =
             Config.save(dir, "1.0.0", :crypto.strong_rand_bytes(1_048_577))

    assert File.read!(path) == :binary.copy("x", 1_048_577)
  end

  test "symlinks, directories and invalid versions are never followed or written", %{
    tmp_dir: dir
  } do
    target = Path.join(dir, "elsewhere")
    File.write!(target, :erlang.term_to_binary(:secret))
    :ok = Config.save(dir, "1.0.0", :mine)
    File.rm!(file(dir, "1.0.0"))
    File.ln_s!(target, file(dir, "1.0.0"))
    assert {:error, :invalid_configuration} = Config.restore(dir, "1.0.0")
    assert {:error, :invalid_configuration} = Config.delete(dir, "1.0.0")
    assert File.exists?(target)

    for version <- ["../x", "1.0", "", "1.0.0/../../x"] do
      assert {:error, :invalid_version} = Config.save(dir, version, :x)
      assert {:error, :invalid_version} = Config.restore(dir, version)
    end
  end

  test "a failed save leaves the previous term", %{tmp_dir: dir} do
    :ok = Config.save(dir, "1.0.0", :previous)
    config = Path.dirname(file(dir, "1.0.0"))
    File.chmod!(config, 0o500)
    on_exit(fn -> File.chmod(config, 0o700) end)

    assert {:error, _} = Config.save(dir, "1.0.0", :next)
    File.chmod!(config, 0o700)
    assert {:ok, :previous} = Config.restore(dir, "1.0.0")
  end
end
