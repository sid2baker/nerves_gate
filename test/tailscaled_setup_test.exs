defmodule Workbench.TailscaledSetupTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "upstream installer bootstraps offline without Mix, target compilation or a daemon", %{
    tmp_dir: dir
  } do
    binary = "fixture binary: must never be executed"
    archive = Path.join(dir, "archive.tgz")

    assert :ok =
             :erl_tar.create(
               String.to_charlist(archive),
               [{~c"tailscale_1.104.1_amd64/tailscaled", binary}],
               [:compressed]
             )

    checksum = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
    cache = Path.join(dir, "cache")
    File.mkdir!(cache)
    File.cp!(archive, Path.join(cache, "tailscale_1.104.1_amd64-#{checksum}.tgz"))
    destination = Path.join(dir, "overlay/usr/sbin/tailscaled")
    installer = Path.join(Workbench.root(), "deps/tailscaled_ex/lib/tailscaled/installer.ex")

    script = """
    Code.require_file(#{inspect(installer)})
    :ok = Tailscaled.Installer.install!(#{inspect(destination)},
      arch: "amd64",
      version: "1.104.1",
      sha256: #{inspect(checksum)},
      cache_dir: #{inspect(cache)},
      offline: true
    )
    false = :code.is_loaded(Mix)
    false = :code.is_loaded(Tailscaled)
    false = List.keymember?(Application.started_applications(), :tailscaled_ex, 0)
    IO.write("installed")
    """

    assert {"installed", 0} =
             System.cmd(
               System.find_executable("elixir"),
               ["--erl", "+S 1:1 +SDio 1 +SDcpu 1", "-e", script],
               env: [{"MIX_TARGET", "ec100"}, {"REBAR_TARGET_ARCH", nil}],
               stderr_to_stdout: true
             )

    assert File.read!(destination) == binary
    assert Bitwise.band(File.stat!(destination).mode, 0o777) == 0o755
  end
end
