defmodule Workbench.AppReleasesTest do
  use ExUnit.Case, async: false
  alias Workbench.AppReleases
  @moduletag :tmp_dir

  test "app tags and notes are distinct from platform/SDK publication", %{tmp_dir: root} do
    path = Path.join(root, "apps/tailnet_subrouter")
    File.mkdir_p!(path)
    notes = "### Added\n\n- Application-owned controls."

    File.write!(
      Path.join(path, "CHANGELOG.md"),
      "# Changelog\n\n## Unreleased\n\n## 1.1.0 - 2026-10-26\n\n#{notes}\n"
    )

    info = AppReleases.metadata!("apps/tailnet_subrouter/v1.1.0", root)
    assert info.notes == notes
    assert info.tag == "apps/tailnet_subrouter/v1.1.0"
    refute info.prerelease

    for tag <- [
          "v1.1.0",
          "sdk/v1.1.0",
          "apps/unknown/v1.1.0",
          "apps/tailnet_subrouter/v1.1.0+dirty"
        ] do
      assert_raise RuntimeError, fn -> AppReleases.metadata!(tag, root) end
    end
  end

  test "release preparation refuses uncommitted source instead of stamping old HEAD", %{
    tmp_dir: root
  } do
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: root)
    File.write!(Path.join(root, "source"), "source")

    assert_raise RuntimeError, ~r/clean committed checkout/, fn ->
      AppReleases.clean_revision!(root)
    end

    {_, 0} = System.cmd("git", ["add", "source"], cd: root)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Release Test",
          "-c",
          "user.email=release@example.test",
          "commit",
          "--quiet",
          "-m",
          "Fixture"
        ],
        cd: root
      )

    assert AppReleases.clean_revision!(root) =~ ~r/\A[0-9a-f]{40}\z/
    File.write!(Path.join(root, "source"), "changed")

    assert_raise RuntimeError, ~r/clean committed checkout/, fn ->
      AppReleases.clean_revision!(root)
    end
  end

  test "app publisher keeps canonical notes, immutable assets and exact-commit qualification" do
    workflow = File.read!(Path.join(Workbench.root(), ".github/workflows/app-release.yml"))
    assert workflow =~ "tags: ['apps/*/v*']"
    assert workflow =~ "environment: app-release"
    assert workflow =~ "mix app.release integration"
    assert workflow =~ "mix app.release unpublished"
    assert workflow =~ "--notes-file"
    assert workflow =~ "--verify-tag"
    assert workflow =~ "--latest=false"
    assert workflow =~ "mix app.release verify"
    assert workflow =~ "mix hex.audit"
    refute workflow =~ "--generate-notes"
    refute workflow =~ "--clobber"
    refute workflow =~ "hex.publish"
  end
end
