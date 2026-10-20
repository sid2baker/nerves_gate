defmodule ReleaseNotesTest do
  use ExUnit.Case, async: false

  @script Path.expand("../scripts/release_notes.exs", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ec100-release-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "VERSION"), "0.2.0-rc.1\n")
    %{dir: dir}
  end

  test "copies only the matching section, preserving Markdown", %{dir: dir} do
    notes = "### Added\n\n- EC100 support with `A/B` updates.\n- [Source](https://example.com)."

    changelog = """
    # Changelog

    ## Unreleased

    ## 0.2.0-rc.1 - 2026-10-15

    #{notes}

    ## 0.1.0 - 2026-09-01

    - Previous release.
    """

    assert {notes <> "\n", 0} == extract(dir, changelog)
  end

  test "rejects a tag that does not match VERSION", %{dir: dir} do
    for tag <- ["system-ec100/v0.2.0", "v0.2.0-rc.1"] do
      {output, status} = extract(dir, "", tag)
      assert status != 0
      assert output =~ "does not match VERSION"
    end
  end

  test "rejects development releases", %{dir: dir} do
    File.write!(Path.join(dir, "VERSION"), "0.2.0-dev\n")
    {output, status} = extract(dir, "", "system-ec100/v0.2.0-dev")
    assert status != 0
    assert output =~ "Choose a release version"
  end

  test "rejects missing, duplicate, empty, and invalid-date sections", %{dir: dir} do
    for changelog <- [
          "# Changelog\n\n## Unreleased\n",
          "# Changelog\n\n## 0.2.0-rc.1 - 2026-10-15\n\n",
          "# Changelog\n\n## 0.2.0-rc.1 - not-a-date\n\n- Change.\n",
          "# Changelog\n\n## 0.2.0-rc.1 - 2026-10-15\n- One.\n\n## 0.2.0-rc.1 - 2026-10-15\n- Two.\n"
        ] do
      {_, status} = extract(dir, changelog)
      assert status != 0
    end
  end

  defp extract(dir, changelog, tag \\ "system-ec100/v0.2.0-rc.1") do
    File.write!(Path.join(dir, "CHANGELOG.md"), changelog)
    System.cmd("elixir", [@script, tag], cd: dir, stderr_to_stdout: true)
  end
end
