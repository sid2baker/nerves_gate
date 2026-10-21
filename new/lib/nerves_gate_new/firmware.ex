defmodule NervesGateNew.Firmware do
  @moduledoc false

  # Keep workspace setup reproducible; never follow a moving "latest" release.
  @url "https://github.com/sid2baker/nerves_gate/releases/download/firmware/v0.1.0/nerves_gate-x86_64-0.1.0.fw"
  @sha256 "398d9e450771ce2bbbb5bbc1c75480eeb29a436a17f2688b6ae0b3657cf98c40"

  def setup!(config_file) do
    {config, _} = Code.eval_file(config_file)
    path = Path.expand(Map.fetch!(config, :firmware))
    default = Path.expand("../firmware/nerves_gate.fw", Path.dirname(config_file))

    cond do
      File.regular?(path) ->
        :ok

      path == default ->
        fetch!(path, @url, @sha256)

      true ->
        Mix.raise(
          "Custom firmware file not found: #{path}. Supply it or restore the default path in config/simulator.exs."
        )
    end
  end

  # Public for focused transfer tests using a real loopback HTTP server.
  @doc false
  def fetch!(path, url, sha256) do
    cond do
      File.regular?(path) ->
        :ok

      File.lstat(path) != {:error, :enoent} ->
        Mix.raise("Firmware destination already exists: #{path}")

      true ->
        download!(path, url, sha256)
    end
  end

  defp download!(path, url, sha256) do
    {:ok, _} = Application.ensure_all_started(:req)
    File.mkdir_p!(Path.dirname(path))
    temporary = "#{path}.#{System.pid()}.#{System.unique_integer([:positive])}.part"
    Mix.shell().info("Downloading QEMU firmware to #{path}")

    try do
      case Req.get(url,
             into: File.stream!(temporary, [:write, :binary, :exclusive]),
             decode_body: false,
             retry: false,
             connect_options: [timeout: 10_000],
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200}} ->
          :ok

        {:ok, %{status: status}} ->
          Mix.raise("Firmware download failed (HTTP #{status}); rerun mix setup to retry.")

        {:error, _} ->
          Mix.raise("Firmware download failed; check your connection and rerun mix setup.")
      end

      unless checksum(temporary) == sha256,
        do:
          Mix.raise(
            "Firmware checksum mismatch; no image was installed. Rerun mix setup to retry."
          )

      # Atomic publication without replacing a file created by another setup or
      # by the developer during the download. Both names are on the same volume.
      case File.ln(temporary, path) do
        :ok ->
          :ok

        {:error, :eexist} ->
          if File.regular?(path),
            do: :ok,
            else: Mix.raise("Firmware destination already exists: #{path}")

        {:error, reason} ->
          Mix.raise("Cannot install firmware: #{:file.format_error(reason)}")
      end
    after
      File.rm(temporary)
    end
  end

  defp checksum(path) do
    path
    |> File.stream!(1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
