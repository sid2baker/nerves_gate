defmodule Workbench.ReleaseToolingTest do
  use ExUnit.Case, async: false
  alias Workbench.Release

  test "release metadata requires a known tag, exact version and canonical dated notes" do
    root = Path.join(System.tmp_dir!(), "gate_notes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sdk"))
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "sdk/VERSION"), "1.0.0\n")

    changelog =
      "# Changelog\n\n## Unreleased\n\n## 1.0.0 - 2026-10-20\n\n### Added\n\n- SDK.\n\n## 0.9.0 - 2026-10-19\n\n- Older.\n"

    File.write!(Path.join(root, "sdk/CHANGELOG.md"), changelog)
    info = Release.metadata!("sdk/v1.0.0", root)
    assert info.app == "nerves_gate_sdk"
    assert info.notes == "### Added\n\n- SDK."
    refute info.prerelease
    output = Path.join(root, "outputs")
    notes = Path.join(root, "notes.md")
    Release.prepare!(info.tag, root, output, notes)
    assert File.read!(notes) == info.notes
    assert File.read!(output) =~ "app=nerves_gate_sdk\n"
    assert_raise RuntimeError, fn -> Release.metadata!("sdk/v1.0.1", root) end

    for tag <- ["other/v1.0.0", "sdk/v1.0.0\n", "../sdk/v1.0.0", "sdk/v1.0.0+build"] do
      assert_raise RuntimeError, fn -> Release.metadata!(tag, root) end
    end

    assert_raise RuntimeError, fn -> Release.notes!("## Unreleased\n", "1.0.0") end
    assert_raise RuntimeError, fn -> Release.notes!(changelog <> changelog, "1.0.0") end
    assert_raise RuntimeError, fn -> Release.notes!("## 1.0.0 - 2026-10-20\n", "1.0.0") end
  end

  test "platform metadata uses the root version and canonical changelog" do
    root =
      Path.join(System.tmp_dir!(), "gate_platform_notes_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "VERSION"), "0.2.0\n")

    File.write!(
      Path.join(root, "CHANGELOG.md"),
      "## Unreleased\n\n## 0.2.0 - 2026-10-21\n\n### Added\n\n- Workbench.\n"
    )

    info = Release.metadata!("v0.2.0", root)
    assert info.project == "."
    assert info.app == "nerves_gate_workbench"
    assert info.notes == "### Added\n\n- Workbench."
    assert :ok = Release.dependencies!(info, root)
    assert_raise RuntimeError, fn -> Release.metadata!("v0.2.1", root) end
  end
end
