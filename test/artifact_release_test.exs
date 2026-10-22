defmodule Dev.ArtifactReleaseTest do
  use ExUnit.Case, async: false
  alias Mix.Tasks.Nerves.Artifact.Release, as: Release

  test "EC100 publication requires the binary, source archive and checksum manifest" do
    binary = "nerves_system_ec100-portable-0.2.1-ABC1234.tar.gz"
    source = "nerves_system_ec100-sources-0.2.1-ABC1234.tar.gz"
    names = Release.asset_names(:nerves_system_ec100, binary)
    assert names == [binary, source, "SHA256SUMS"]

    assets =
      for name <- names, do: %{"name" => name, "state" => "uploaded", "digest" => "sha256:abc"}

    assert Release.assets_uploaded?(%{"assets" => assets}, names)
    refute Release.assets_uploaded?(%{"assets" => tl(assets)}, names)
    refute Release.assets_uploaded?(%{"assets" => Enum.take(assets, 1)}, names)
    refute Release.assets_uploaded?(%{"assets" => [%{hd(assets) | "digest" => nil}]}, [binary])
    refute Release.assets_uploaded?(%{"assets" => [%{hd(assets) | "state" => "new"}]}, [binary])
  end

  test "source prefetch uses Buildroot before compiling, not a separate downloader" do
    {script, []} = Release.buildroot_command(:source, :nerves_system_ec100, "unused")

    assert script =~
             "create-build.sh /workspace/nerves_system_ec100/nerves_defconfig /workspace/build"

    assert script =~ "exec make source"
    refute script =~ "curl"
    refute script =~ "make all"
  end

  @tag :tmp_dir
  test "legal-info failure stops collection before packaging", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "Makefile"),
      "legal-info:\n\t@exit 17\nsystem:\n\t@touch should-not-exist\n"
    )

    {script, args} = Release.buildroot_command(:collect, :nerves_system_ec100, "system.tar.gz")
    assert script =~ "make legal-info"
    assert script =~ "share/licenses"
    assert script =~ "ct-ng.config"
    refute script =~ "curl"
    assert args == ["NERVES_ARTIFACT_NAME=system"]

    assert {_, 2} =
             System.cmd("sh", ["-ec", script, "buildroot" | args],
               cd: dir,
               stderr_to_stdout: true
             )

    refute File.exists?(Path.join(dir, "should-not-exist"))
  end

  @tag :tmp_dir
  test "standard collection retains installed notices/configuration before packaging", %{
    tmp_dir: dir
  } do
    toolchain = Path.join(dir, "host/opt/ext-toolchain")
    File.mkdir_p!(Path.join(toolchain, "share/licenses"))
    File.write!(Path.join(toolchain, "share/licenses/NOTICE"), "installed notices")

    for name <- ["ct-ng.config", "ct-ng.defconfig"],
        do: File.write!(Path.join(toolchain, name), name)

    File.write!(
      Path.join(dir, "Makefile"),
      "legal-info:\n\t@mkdir -p legal-info\nsystem:\n\t@printf '%s' '$(NERVES_ARTIFACT_NAME)' > artifact-name\n"
    )

    {script, args} = Release.buildroot_command(:collect, :nerves_system_ec100, "system.tar.gz")

    assert {_, 0} =
             System.cmd("sh", ["-ec", script, "buildroot" | args],
               cd: dir,
               stderr_to_stdout: true
             )

    assert File.read!(Path.join(dir, "artifact-name")) == "system"

    assert File.read!(Path.join(dir, "legal-info/licenses/toolchain-external-custom/NOTICE")) ==
             "installed notices"

    assert File.read!(Path.join(dir, "legal-info/toolchain-external-custom/ct-ng.config")) ==
             "ct-ng.config"
  end

  @tag :tmp_dir
  test "publication verifies standard SHA256SUMS and rejects changed files", %{tmp_dir: dir} do
    archive = Path.join(dir, "cached-system.tar.gz")
    binary = Path.join(dir, "system.tar.gz")
    sources = Path.join(dir, "sources.tar.gz")
    checksums = Path.join(dir, "SHA256SUMS")
    File.write!(archive, "built binary")
    File.cp!(archive, binary)
    File.write!(sources, "collected sources")

    {manifest, 0} =
      System.cmd("sha256sum", [Path.basename(binary), Path.basename(sources)], cd: dir)

    File.write!(checksums, manifest)
    paths = [binary, sources, checksums]
    assert :ok = Release.verify_assets!(archive, paths)

    File.write!(checksums, String.replace(manifest, "\n", "\\n"))
    assert_raise Mix.Error, ~r/SHA256SUMS/, fn -> Release.verify_assets!(archive, paths) end
    File.write!(checksums, manifest)

    for path <- [archive, binary, sources] do
      original = File.read!(path)
      File.write!(path, "changed bytes")
      assert_raise Mix.Error, ~r/SHA256SUMS/, fn -> Release.verify_assets!(archive, paths) end
      File.write!(path, original)
    end

    assert :ok = Release.verify_assets!(archive, paths)
  end

  test "QEMU publication requires its fingerprinted binary" do
    binary = "nerves_system_ec100_qemu-portable-0.2.2-ABC1234.tar.gz"
    assert Release.asset_names(:nerves_system_ec100_qemu, binary) == [binary]
    refute Release.assets_uploaded?(%{"assets" => []}, [binary])
  end
end
