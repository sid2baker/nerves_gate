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
