defmodule NervesGateSim.ArtifactReleaseTest do
  use ExUnit.Case, async: false
  alias Mix.Tasks.Nerves.Artifact.Release, as: Release

  test "release lookup, canonical notes and immutable source checks" do
    NervesGate.Scenarios.SystemArtifact.assert_tooling_contract()
  end

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

  test "QEMU publication requires its fingerprinted binary" do
    binary = "nerves_system_ec100_qemu-portable-0.2.2-ABC1234.tar.gz"
    assert Release.asset_names(:nerves_system_ec100_qemu, binary) == [binary]
    refute Release.assets_uploaded?(%{"assets" => []}, [binary])
  end
end
