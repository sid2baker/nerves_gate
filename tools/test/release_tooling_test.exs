defmodule NervesGateTools.ReleaseToolingTest do
  use ExUnit.Case, async: false
  alias NervesGateTools.PackageRelease

  test "release metadata requires a known tag, exact version and canonical dated notes" do
    root = Path.join(System.tmp_dir!(), "gate_notes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sdk"))
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "sdk/VERSION"), "1.0.0\n")

    changelog =
      "# Changelog\n\n## Unreleased\n\n## 1.0.0 - 2026-10-20\n\n### Added\n\n- SDK.\n\n## 0.9.0 - 2026-10-19\n\n- Older.\n"

    File.write!(Path.join(root, "sdk/CHANGELOG.md"), changelog)
    info = PackageRelease.metadata!("sdk/v1.0.0", root)
    assert info.app == "nerves_gate_sdk"
    assert info.notes == "### Added\n\n- SDK."
    refute info.prerelease
    output = Path.join(root, "outputs")
    notes = Path.join(root, "notes.md")
    PackageRelease.prepare!(info.tag, root, output, notes)
    assert File.read!(notes) == info.notes
    assert File.read!(output) =~ "app=nerves_gate_sdk\n"
    assert_raise RuntimeError, fn -> PackageRelease.metadata!("sdk/v1.0.1", root) end

    for tag <- ["other/v1.0.0", "sdk/v1.0.0\n", "../sdk/v1.0.0", "sdk/v1.0.0+build"] do
      assert_raise RuntimeError, fn -> PackageRelease.metadata!(tag, root) end
    end

    assert_raise RuntimeError, fn -> PackageRelease.notes!("## Unreleased\n", "1.0.0") end
    assert_raise RuntimeError, fn -> PackageRelease.notes!(changelog <> changelog, "1.0.0") end
    assert_raise RuntimeError, fn -> PackageRelease.notes!("## 1.0.0 - 2026-10-20\n", "1.0.0") end
  end

  test "installed archive includes dotfile templates and works outside the repository" do
    root = Path.join(System.tmp_dir!(), "gate_archive_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    paths = :code.get_path()

    archive =
      try do
        Mix.Project.in_project(:nerves_gate_new, Path.expand("../../new", __DIR__), fn _ ->
          output = Path.join(root, "nerves_gate_new-#{Mix.Project.config()[:version]}.ez")
          Mix.Task.reenable("deps.loadpaths")
          Mix.Task.run("deps.loadpaths")
          Mix.Task.reenable("deps.compile")
          Mix.Task.run("deps.compile")
          Mix.Task.reenable("archive.build")
          Mix.Task.run("archive.build", ["--output", output])
          output
        end)
      after
        :code.set_path(paths)
      end

    assert :ok = NervesGateTools.ArchiveSmoke.run!(archive)
  end
end
