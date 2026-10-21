defmodule NervesGateNew.FirmwareTest do
  use ExUnit.Case, async: false
  alias NervesGateNew.Firmware

  setup do
    root = Path.join(System.tmp_dir!(), "gate_firmware_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "config"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, path: Path.join(root, "firmware/nerves_gate.fw")}
  end

  test "streams and verifies an image, with no partial output left behind", %{
    root: root,
    path: path
  } do
    body = :binary.copy("firmware bytes", 10_000)

    serve(body, 200, fn url ->
      assert :ok = Firmware.fetch!(path, url, sha256(body))
    end)

    assert File.read!(path) == body
    assert Path.wildcard(Path.join(root, "firmware/*.part")) == []
  end

  test "HTTP errors and checksum mismatches never install a partial image", %{
    root: root,
    path: path
  } do
    serve("not found", 404, fn url ->
      assert_raise Mix.Error, ~r/HTTP 404/, fn -> Firmware.fetch!(path, url, sha256("image")) end
    end)

    serve("wrong bytes", 200, fn url ->
      assert_raise Mix.Error, ~r/checksum mismatch/, fn ->
        Firmware.fetch!(path, url, sha256("image"))
      end
    end)

    refute File.exists?(path)
    assert Path.wildcard(Path.join(root, "firmware/*.part")) == []
  end

  test "a disconnected transfer can be retried without reusing partial bytes", %{
    root: root,
    path: path
  } do
    serve(
      "partial",
      200,
      fn url ->
        assert_raise Mix.Error, ~r/download failed/, fn ->
          Firmware.fetch!(path, url, sha256("image"))
        end
      end,
      content_length: 1000
    )

    refute File.exists?(path)
    assert Path.wildcard(Path.join(root, "firmware/*.part")) == []
    serve("image", 200, fn url -> Firmware.fetch!(path, url, sha256("image")) end)
    assert File.read!(path) == "image"
  end

  test "setup preserves existing default and custom images without downloading", %{
    root: root,
    path: path
  } do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "my image")
    config = Path.join(root, "config/simulator.exs")
    File.write!(config, inspect(%{firmware: path}))
    assert :ok = Firmware.setup!(config)
    assert :ok = Firmware.fetch!(path, "http://127.0.0.1:1", sha256("different image"))
    assert File.read!(path) == "my image"

    custom = Path.join(root, "custom.fw")
    File.write!(custom, "custom image")
    File.write!(config, inspect(%{firmware: custom}))
    assert :ok = Firmware.setup!(config)
    assert File.read!(custom) == "custom image"
  end

  test "missing custom paths are not silently populated with the default image", %{
    root: root,
    path: path
  } do
    config = Path.join(root, "config/simulator.exs")
    File.write!(config, inspect(%{firmware: Path.join(root, "custom.fw")}))
    assert_raise Mix.Error, ~r/Custom firmware file not found/, fn -> Firmware.setup!(config) end
    refute File.exists?(path)
  end

  test "existing destinations and files created during download are never replaced", %{
    root: root,
    path: path
  } do
    File.mkdir_p!(path)

    assert_raise Mix.Error, ~r/destination already exists/, fn ->
      Firmware.fetch!(path, "http://127.0.0.1:1", sha256("image"))
    end

    File.rmdir!(path)
    File.ln_s!(Path.join(root, "absent"), path)

    assert_raise Mix.Error, ~r/destination already exists/, fn ->
      Firmware.fetch!(path, "http://127.0.0.1:1", sha256("image"))
    end

    File.rm!(path)

    serve(
      "image",
      200,
      fn url ->
        assert :ok = Firmware.fetch!(path, url, sha256("image"))
      end,
      before_send: fn -> File.write!(path, "provided by user") end
    )

    assert File.read!(path) == "provided by user"
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  # Exercise real HTTP streaming rather than replacing the HTTP client.
  defp serve(body, status, run, options \\ []) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, _} = :gen_tcp.recv(socket, 0, 5_000)
        Keyword.get(options, :before_send, fn -> :ok end).()
        length = Keyword.get(options, :content_length, byte_size(body))

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} Response\r\nContent-Length: #{length}\r\nConnection: close\r\n\r\n#{body}"
          )

        :gen_tcp.close(socket)
      end)

    try do
      run.("http://127.0.0.1:#{port}/firmware.fw")
      Task.await(task, 5_000)
    after
      Task.shutdown(task, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end
end
