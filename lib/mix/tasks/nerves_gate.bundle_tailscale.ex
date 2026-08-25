defmodule Mix.Tasks.NervesGate.BundleTailscale do
  @moduledoc "Downloads and verifies the pinned x86_64 Tailscale release for firmware inclusion."
  use Mix.Task

  @shortdoc "Bundle the pinned Tailscale binaries"

  @impl true
  def run(_arguments) do
    Mix.Task.run("app.start")
    version = Application.fetch_env!(:nerves_gate, :tailscale_version)
    destination = Path.expand("rootfs_overlay/usr/lib/nerves_gate/tailscale")
    cache = Path.join(destination, ".verified")

    case Tailscale.Binary.ensure_installed(version: version, install_dir: cache, timeout: 60_000) do
      {:ok, paths} ->
        File.mkdir_p!(destination)
        copy_executable(paths.cli_path, Path.join(destination, "tailscale"))
        copy_executable(paths.daemon_path, Path.join(destination, "tailscaled"))
        File.rm_rf!(cache)
        Mix.shell().info("Bundled verified Tailscale #{version}")

      {:error, reason} ->
        Mix.raise("Unable to bundle pinned Tailscale release: #{inspect(reason)}")
    end
  end

  defp copy_executable(source, destination) do
    File.cp!(source, destination)
    File.chmod!(destination, 0o755)
  end
end

defmodule Mix.Tasks.NervesGate.VerifyTailscaleBundle do
  @moduledoc "Stops firmware builds that would rely only on a runtime Tailscale download."
  use Mix.Task

  @shortdoc "Verify bundled Tailscale executables"

  @impl true
  def run(_arguments) do
    expected = Application.fetch_env!(:nerves_gate, :tailscale_binary_sha256)

    paths = [
      {"rootfs_overlay/usr/lib/nerves_gate/tailscale/tailscale", expected.cli},
      {"rootfs_overlay/usr/lib/nerves_gate/tailscale/tailscaled", expected.daemon}
    ]

    unless Enum.all?(paths, fn {path, checksum} ->
             executable?(path) and sha256(path) == checksum
           end) do
      Mix.raise("""
      Pinned Tailscale binaries are not bundled.
      Run `mix nerves_gate.bundle_tailscale` before `mix firmware`.
      """)
    end
  end

  defp sha256(path) do
    path
    |> File.stream!(1_048_576, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end
end
