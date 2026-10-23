defmodule NervesGate.Network.CellularPINTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias NervesGate.Network.CellularPIN

  @identity "89880000000000000001"
  @other_sim "89880000000000000002"
  @pin "4812"
  @storage_error {:error, :cellular_pin_storage}

  setup do
    root = Path.join(System.tmp_dir!(), "cellular-pin-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: Path.join(root, "private/pin.json")}
  end

  test "missing storage is off; forget does not create directories", %{path: path} do
    assert CellularPIN.metadata(nil, path) == %{pin_saved: false, auto_unlock: :off}
    assert CellularPIN.forget(path) == :ok
    refute File.exists?(Path.dirname(path))
    assert CellularPIN.consume(@identity, path) == {:error, :cellular_pin_not_saved}
  end

  test "saved credential survives reload, is private and stores no raw SIM identity", %{
    path: path
  } do
    assert CellularPIN.save(@pin, @identity, path) == :ok
    assert band(File.stat!(path).mode, 0o777) == 0o600
    assert band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
    refute File.read!(path) =~ @identity

    assert CellularPIN.metadata(@identity, path) == %{pin_saved: true, auto_unlock: :ready}
    assert CellularPIN.metadata(nil, path) == %{pin_saved: true, auto_unlock: :identity_unknown}
    assert File.ls!(Path.dirname(path)) == ["pin.json"]
  end

  test "automatic attempt is blocked durably before its credential is returned", %{path: path} do
    assert CellularPIN.save(@pin, @identity, path) == :ok
    assert CellularPIN.consume(@identity, path) == {:ok, @pin}
    assert CellularPIN.metadata(@identity, path) == %{pin_saved: true, auto_unlock: :blocked}
    assert CellularPIN.consume(@identity, path) == {:error, :cellular_auto_unlock_blocked}
    assert CellularPIN.block(path) == :ok
    assert CellularPIN.consume(@identity, path) == {:error, :cellular_auto_unlock_blocked}

    # Only the caller's known-successful explicit verification may save/arm again.
    assert CellularPIN.save(@pin, @identity, path) == :ok
    assert CellularPIN.metadata(@identity, path).auto_unlock == :ready
  end

  test "unknown identity and a different SIM cannot consume or change the record", %{path: path} do
    assert CellularPIN.save(@pin, @identity, path) == :ok
    bytes = File.read!(path)
    assert CellularPIN.metadata(@other_sim, path).auto_unlock == :different_sim

    for identity <- [nil, "", "123", @other_sim] do
      assert CellularPIN.consume(identity, path) == {:error, :cellular_auto_unlock_blocked}
      assert File.read!(path) == bytes
    end
  end

  test "manual security writes can block old credentials without using them", %{path: path} do
    assert CellularPIN.block(path) == :ok
    assert CellularPIN.save(@pin, @identity, path) == :ok
    assert CellularPIN.block(path) == :ok
    assert CellularPIN.metadata(nil, path).auto_unlock == :blocked
  end

  test "explicit forget removes blocked credentials, not SIM settings", %{path: path} do
    assert CellularPIN.save(@pin, @identity, path) == :ok
    assert CellularPIN.block(path) == :ok
    assert CellularPIN.forget(path) == :ok
    refute File.exists?(path)
    assert CellularPIN.metadata(@identity, path) == %{pin_saved: false, auto_unlock: :off}
  end

  test "a crashed staging write is never loaded and explicit forget removes its secret", %{
    path: path
  } do
    assert CellularPIN.save(@pin, @identity, path) == :ok
    armed_bytes = File.read!(path)
    File.write!(path <> ".new", armed_bytes)
    File.chmod!(path <> ".new", 0o600)
    assert CellularPIN.block(path) == :ok
    File.write!(path <> ".new", armed_bytes)
    File.chmod!(path <> ".new", 0o600)
    assert CellularPIN.metadata(@identity, path).auto_unlock == :blocked
    assert CellularPIN.consume(@identity, path) == {:error, :cellular_auto_unlock_blocked}
    assert CellularPIN.forget(path) == :ok
    refute File.exists?(path <> ".new")
    refute File.exists?(path)
  end

  test "an unsafe staging destination cannot release a PIN", %{root: root, path: path} do
    assert CellularPIN.save(@pin, @identity, path) == :ok
    outside = Path.join(root, "outside")
    File.write!(outside, "untouched")
    File.ln_s!(outside, path <> ".new")
    assert CellularPIN.consume(@identity, path) == @storage_error
    assert File.read!(outside) == "untouched"
    assert File.lstat!(path <> ".new").type == :symlink
  end

  test "invalid parameters cannot create or overwrite storage", %{path: path} do
    for pin <- [nil, "123", "123456789", "１２３４", "1234\rAT+CFUN=0"] do
      assert CellularPIN.save(pin, @identity, path) == @storage_error
    end

    assert CellularPIN.save(@pin, "not-an-iccid", path) == @storage_error
    refute File.exists?(path)
    assert CellularPIN.save(@pin, @identity, path) == :ok
    bytes = File.read!(path)
    assert CellularPIN.save("invalid", @identity, path) == @storage_error
    assert File.read!(path) == bytes
  end

  test "corrupt, oversized and unexpected schemas fail closed without overwriting", %{path: path} do
    assert CellularPIN.save(@pin, @identity, path) == :ok
    valid = path |> File.read!() |> Jason.decode!()

    for bytes <- [
          "not json",
          "",
          String.duplicate("x", 1025),
          Jason.encode!(%{valid | "version" => 2}),
          Jason.encode!(%{valid | "armed" => "true"}),
          Jason.encode!(Map.put(valid, "extra", "ignored?")),
          Jason.encode!(%{valid | "fingerprint" => @identity})
        ] do
      File.write!(path, bytes)

      assert CellularPIN.metadata(@identity, path) == %{
               pin_saved: nil,
               auto_unlock: :storage_error
             }

      assert CellularPIN.consume(@identity, path) == @storage_error
      assert CellularPIN.block(path) == @storage_error
      assert CellularPIN.save(@pin, @identity, path) == @storage_error
      assert File.read!(path) == bytes
    end
  end

  test "explicit forget can remove corrupt private storage", %{path: path} do
    assert CellularPIN.save(@pin, @identity, path) == :ok
    File.write!(path, "corrupt")
    assert CellularPIN.forget(path) == :ok
    assert CellularPIN.metadata(nil, path).auto_unlock == :off
  end

  test "insecure files and directories are never silently repaired", %{path: path} do
    assert CellularPIN.save(@pin, @identity, path) == :ok
    bytes = File.read!(path)

    for target <- [path, Path.dirname(path)] do
      original = band(File.stat!(target).mode, 0o777)
      File.chmod!(target, 0o755)
      assert CellularPIN.metadata(@identity, path).auto_unlock == :storage_error
      assert CellularPIN.consume(@identity, path) == @storage_error
      assert CellularPIN.save(@pin, @identity, path) == @storage_error
      assert CellularPIN.forget(path) == @storage_error
      assert File.read!(path) == bytes
      File.chmod!(target, original)
    end
  end

  test "symlinked files, directories and ancestors are rejected", %{root: root, path: path} do
    assert CellularPIN.save(@pin, @identity, path) == :ok
    alias_path = Path.join(root, "alias.json")
    File.ln_s!(path, alias_path)
    assert CellularPIN.consume(@identity, alias_path) == @storage_error
    assert CellularPIN.forget(alias_path) == @storage_error

    alias_dir = Path.join(root, "alias-dir")
    File.ln_s!(Path.dirname(path), alias_dir)

    for destination <- [Path.join(alias_dir, "pin.json"), Path.join(alias_dir, "new/pin.json")] do
      assert CellularPIN.save(@pin, @identity, destination) == @storage_error
      assert CellularPIN.consume(@identity, destination) == @storage_error
      assert CellularPIN.forget(destination) == @storage_error
    end

    assert CellularPIN.metadata(@identity, path).auto_unlock == :ready
  end

  test "hard-linked records and non-regular destinations are rejected", %{root: root, path: path} do
    assert CellularPIN.save(@pin, @identity, path) == :ok
    File.ln!(path, Path.join(root, "hard-link"))
    assert CellularPIN.consume(@identity, path) == @storage_error
    assert CellularPIN.save(@pin, @identity, path) == @storage_error
    assert CellularPIN.forget(path) == @storage_error

    directory_path = Path.join(Path.dirname(path), "directory.json")
    File.mkdir!(directory_path)
    assert CellularPIN.consume(@identity, directory_path) == @storage_error
    assert CellularPIN.save(@pin, @identity, directory_path) == @storage_error
  end
end
