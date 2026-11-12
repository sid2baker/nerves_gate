defmodule Workbench.ArtifactReleaseTest do
  use ExUnit.Case, async: false
  alias Mix.Tasks.Nerves.Artifact.Release, as: Release

  test "the monorepo publisher only accepts the owned QEMU system" do
    package = %{app: :nerves_system_ec100_qemu}

    plan = %{
      actions: [{Nerves.BuildAction.NervesV1System, [app: package.app]}],
      packages: [package]
    }

    assert Release.system_package!(plan) == package

    for app <- [:nerves_system_ec100, :nerves_system_em300] do
      physical = %{plan | actions: [{Nerves.BuildAction.NervesV1System, [app: app]}]}
      assert_raise Mix.Error, ~r/own repositories/, fn -> Release.system_package!(physical) end
    end

    assert_raise Mix.Error, fn -> Release.system_package!(%{actions: [], packages: []}) end
    assert_raise Mix.Error, fn -> Release.system_package!(%{plan | packages: []}) end
  end

  test "publication requires one public snapshot with the uploaded QEMU archive" do
    names = ["nerves_system_ec100_qemu-portable-0.2.2-ABC1234.tar.gz"]
    asset = %{"name" => hd(names), "state" => "uploaded", "digest" => "sha256:abc"}
    draft = %{"draft" => true, "assets" => [asset]}
    published = %{draft | "draft" => false}

    refute Release.published?(draft, names)
    assert Release.published?(published, names)
    refute Release.published?(%{published | "assets" => []}, names)
    refute Release.published?(%{published | "assets" => [%{asset | "digest" => nil}]}, names)
    refute Release.published?(%{published | "assets" => [%{asset | "state" => "new"}]}, names)

    snapshots = [draft, %{published | "assets" => []}, published, draft]
    assert Enum.find(snapshots, &Release.published?(&1, names)) == published
  end

  test "source prefetch uses Buildroot before compiling, not a separate downloader" do
    {script, []} = Release.buildroot_command(:source, :nerves_system_ec100_qemu, "unused")

    assert script =~
             "create-build.sh /workspace/nerves_system_ec100_qemu/nerves_defconfig /workspace/build"

    assert script =~ "exec make source"
    refute script =~ "curl"
    refute script =~ "make all"
  end
end
