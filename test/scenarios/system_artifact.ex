defmodule NervesGate.Scenarios.SystemArtifact do
  @moduledoc false
  import ExUnit.Assertions
  alias Mix.Tasks.Nerves.Artifact.Release, as: Release
  alias NervesGate.TestQemu, as: Qemu

  @system Path.expand("../../systems/nerves_system_ec100_qemu", __DIR__)

  def spec, do: %{:name => "QEMU runs the versioned system and artifact publication stays safe"}

  def run(%{device: vm}) do
    assert Qemu.status(vm).system.node == vm.node
    version = File.read!(Path.join(@system, "VERSION")) |> String.trim()
    assert {:ok, os_release} = :erpc.call(vm.node, File, :read, ["/usr/lib/os-release"], 5_000)
    assert "NERVES_SYSTEM_VERSION=#{version}" in String.split(os_release, "\n")

    assert :erpc.call(vm.node, Nerves.Runtime.KV, :get_active, ["nerves_fw_platform"], 5_000) ==
             "x86_64"

    notes = Release.release_notes!(File.read!(Path.join(@system, "CHANGELOG.md")), version)
    assert notes != ""
    assert_tooling_contract()
  end

  @doc false
  def assert_tooling_contract do
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

  defp check_pending_sources(repository) do
    system = "systems/nerves_system_ec100_qemu"
    tag = "ec100-qemu-v0.1.0"

    sources = [
      {"#{system}/mix.exs", "system definition"},
      {"#{system}/rootfs_overlay/etc/example", "system input"},
      {"mix.lock", "locked dependencies"},
      {"mise.toml", "pinned toolchain"}
    ]

    for {path, content} <- sources do
      path = Path.join(repository, path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    git!(repository, ["init", "--quiet"])
    git!(repository, ["add", "."])
    git!(repository, ["commit", "--quiet", "-m", "System inputs"])
    git!(repository, ["tag", tag])
    assert :ok = Release.verify_pending_sources!(tag, system, repository)

    File.mkdir_p!(Path.join(repository, "dev"))
    File.write!(Path.join(repository, "dev/artifact_release.ex"), "publisher repair")
    git!(repository, ["add", "."])
    git!(repository, ["commit", "--quiet", "-m", "Repair publisher only"])
    refute git!(repository, ["rev-parse", "HEAD"]) == git!(repository, ["rev-parse", tag])
    assert :ok = Release.verify_pending_sources!(tag, system, repository)

    for {path, original} <- sources do
      path = Path.join(repository, path)
      File.write!(path, "changed input")
      assert_pending_sources_rejected(tag, system, repository)
      File.rm!(path)
      assert_pending_sources_rejected(tag, system, repository)
      File.write!(path, original)
    end

    assert :ok = Release.verify_pending_sources!(tag, system, repository)
    File.write!(Path.join(repository, "#{system}/new-input"), "new system input")
    git!(repository, ["add", "."])
    git!(repository, ["commit", "--quiet", "-m", "Changed system inputs"])
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
          "core.hooksPath=/dev/null"
          | args
        ],
        cd: repository,
        stderr_to_stdout: true
      )

    assert status == 0, output
    String.trim(output)
  end

  defp assert_notes_contract do
    changelog = """
    # Changelog

    ## Unreleased

    - Not released yet.

    ## 0.1.0 - 2026-10-14

    ### Added

    - A prebuilt system.

    ## 0.0.1 - 2026-10-01

    - Older notes.
    """

    assert Release.release_notes!(changelog, "0.1.0") == "### Added\n\n- A prebuilt system."
    assert_raise Mix.Error, fn -> Release.release_notes!(changelog, "0.2.0") end
    assert_raise Mix.Error, fn -> Release.release_notes!(changelog <> changelog, "0.1.0") end
    assert_raise Mix.Error, fn -> Release.release_notes!(changelog, "0.1.0-rc.1") end
    assert_raise Mix.Error, fn -> Release.release_notes!("## 0.1.0 - 2026-10-14\n", "0.1.0") end
  end
end
