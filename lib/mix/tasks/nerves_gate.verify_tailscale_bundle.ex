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
