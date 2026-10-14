defmodule NervesGate.Scenarios.SystemArtifact do
  @moduledoc false
  import ExUnit.Assertions
  alias Mix.Tasks.Nerves.Artifact.Release, as: Release
  alias NervesGate.TestQemu, as: Qemu

  @guest :"nerves_gate@192.168.77.2"
  @system Path.expand("../../systems/nerves_system_ec100_qemu", __DIR__)

  def name, do: "QEMU runs the independently versioned system and release notes stay exact"

  def run(vm) do
    assert Qemu.status(vm).system.node == @guest
    version = File.read!(Path.join(@system, "VERSION")) |> String.trim()
    assert {:ok, os_release} = :erpc.call(@guest, File, :read, ["/usr/lib/os-release"], 5_000)
    assert "NERVES_SYSTEM_VERSION=#{version}" in String.split(os_release, "\n")

    assert :erpc.call(@guest, Nerves.Runtime.KV, :get_active, ["nerves_fw_platform"], 5_000) ==
             "x86_64"

    notes = Release.release_notes!(File.read!(Path.join(@system, "CHANGELOG.md")), version)
    assert notes != ""
    assert_notes_contract()
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
