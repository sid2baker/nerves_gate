defmodule Dev.SystemContractTest do
  use ExUnit.Case, async: false

  test "release lookup, canonical notes and immutable source checks" do
    assert_tooling_contract()
  end

  alias Mix.Tasks.Nerves.Artifact.Release, as: Release

  def assert_tooling_contract do
    repo = "sid2baker/nerves_gate"
    tag = "system-ec100-qemu/v1.0.0"
    assert Release.tag!([{:github_releases, repo, tag: tag}]) == tag

    assert Release.tag!([{:github_releases, "other/repo"}, {:github_releases, repo, tag: tag}]) ==
             tag

    assert_raise Mix.Error, fn -> Release.tag!(github_releases: repo) end
    assert_raise Mix.Error, fn -> Release.tag!([]) end
    assert_notes_contract()
    assert_release_lookup_contract()
    assert_pending_sources_contract()
  end

  defp assert_release_lookup_contract do
    tag = "ec100-qemu-v0.1.0"
    draft = %{"tag_name" => tag, "draft" => true, "assets" => []}
    other = %{draft | "tag_name" => "v0.0.1"}

    published = %{
      draft
      | "draft" => false,
        "assets" => [
          %{"name" => "system.tar.gz", "state" => "uploaded", "digest" => "sha256:abc"}
        ]
    }

    assert Release.release_from_response!({JSON.encode!([[other], [draft]]), 0}, tag) == draft
    assert Release.release_from_response!({JSON.encode!([[published]]), 0}, tag) == published
    assert Release.release_from_response!({JSON.encode!([[other]]), 0}, tag) == nil
    assert Release.release_from_response!({JSON.encode!([[]]), 0}, tag) == nil

    assert_raise Mix.Error, ~r/Multiple GitHub releases/, fn ->
      Release.release_from_response!({JSON.encode!([[draft], [published]]), 0}, tag)
    end

    for invalid <- [
          nil,
          %{"status" => "404"},
          [draft],
          [[nil]],
          [[%{draft | "assets" => nil}]],
          [[%{draft | "assets" => [nil]}]],
          [[%{draft | "draft" => nil}]],
          [[Map.delete(draft, "tag_name")]]
        ] do
      assert_raise Mix.Error, ~r/Cannot read GitHub releases/, fn ->
        Release.release_from_response!({JSON.encode!(invalid), 0}, tag)
      end
    end

    for response <- [
          {"not JSON", 0},
          {JSON.encode!(%{"status" => "404"}), 1},
          {JSON.encode!([[draft]]), 1}
        ] do
      assert_raise Mix.Error, ~r/Cannot read GitHub releases/, fn ->
        Release.release_from_response!(response, tag)
      end
    end
  end

  defp assert_pending_sources_contract do
    repository =
      Path.join(
        System.tmp_dir!(),
        "nerves-gate-release-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      )

    File.mkdir!(repository)

    try do
      check_pending_sources(repository)
    after
      File.rm_rf!(repository)
    end
  end

  defp check_pending_sources(root) do
    repository = Path.join(root, "firmware")
    system = "../systems/nerves_system_ec100_qemu"
    tag = "system-ec100-qemu/v0.1.0"

    sources = [
      {"#{system}/mix.exs", "system definition"},
      {"#{system}/rootfs_overlay/etc/example", "system input"},
      {"mix.lock", "locked dependencies"},
      {"../mise.toml", "pinned toolchain"}
    ]

    for {path, content} <- sources do
      path = Path.expand(path, repository)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    git!(root, ["init", "--quiet"])
    git!(root, ["add", "."])
    git!(root, ["commit", "--quiet", "-m", "System inputs"])
    git!(root, ["tag", tag])
    assert :ok = Release.verify_pending_sources!(tag, system, repository)
    File.mkdir_p!(Path.join(root, "lib/dev"))
    File.write!(Path.join(root, "lib/dev/artifact_release.ex"), "publisher repair")
    git!(root, ["add", "."])
    git!(root, ["commit", "--quiet", "-m", "Repair publisher only"])
    refute git!(root, ["rev-parse", "HEAD"]) == git!(root, ["rev-parse", tag])
    assert :ok = Release.verify_pending_sources!(tag, system, repository)

    for {path, original} <- sources do
      path = Path.expand(path, repository)
      File.write!(path, "changed input")
      assert_pending_sources_rejected(tag, system, repository)
      File.rm!(path)
      assert_pending_sources_rejected(tag, system, repository)
      File.write!(path, original)
    end

    assert :ok = Release.verify_pending_sources!(tag, system, repository)
    File.write!(Path.expand("#{system}/new-input", repository), "new system input")
    git!(root, ["add", "."])
    git!(root, ["commit", "--quiet", "-m", "Changed system inputs"])
    assert_pending_sources_rejected(tag, system, repository)

    assert_raise Mix.Error, ~r/Cannot compare pending system inputs/, fn ->
      Release.verify_pending_sources!("missing-tag", system, repository)
    end
  end

  defp assert_pending_sources_rejected(tag, system, repository) do
    assert_raise Mix.Error, ~r/Bump VERSION; do not reuse the tag/, fn ->
      Release.verify_pending_sources!(tag, system, repository)
    end
  end

  defp git!(repository, args) do
    {output, status} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Release scenario",
          "-c",
          "user.email=release-scenario@example.invalid",
          "-c",
          "commit.gpgsign=false",
          "-c",
          "core.hooksPath=/dev/null" | args
        ],
        cd: repository,
        stderr_to_stdout: true
      )

    assert status == 0, output
    String.trim(output)
  end

  defp assert_notes_contract do
    changelog =
      "# Changelog\n\n## Unreleased\n\n- Not released yet.\n\n## 0.1.0 - 2026-10-14\n\n### Added\n\n- A prebuilt system.\n\n## 0.0.1 - 2026-10-01\n\n- Older notes.\n"

    assert Release.release_notes!(changelog, "0.1.0") == "### Added\n\n- A prebuilt system."
    assert_raise Mix.Error, fn -> Release.release_notes!(changelog, "0.2.0") end
    assert_raise Mix.Error, fn -> Release.release_notes!(changelog <> changelog, "0.1.0") end
    assert_raise Mix.Error, fn -> Release.release_notes!(changelog, "0.1.0-rc.1") end
    assert_raise Mix.Error, fn -> Release.release_notes!("## 0.1.0 - 2026-10-14\n", "0.1.0") end
  end
end
