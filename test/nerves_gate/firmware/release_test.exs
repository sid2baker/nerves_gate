defmodule NervesGate.Firmware.ReleaseTest do
  use ExUnit.Case, async: true

  alias NervesGate.Firmware.{Manifest, Release}

  setup do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    %{public_key: public_key, private_key: private_key}
  end

  test "accepts an exact signed compatible manifest", keys do
    contents = Jason.encode!(manifest()) <> "\n"
    signature = :crypto.sign(:eddsa, :none, contents, [keys.private_key, :ed25519])

    assert {:ok, decoded} =
             Manifest.verify(
               contents,
               Base.encode64(signature),
               [Base.encode64(keys.public_key)]
             )

    assert {:ok, release} =
             Release.from_manifest(decoded, "https://example.invalid/nerves_gate.fw")

    assert Release.compatible?(release, current())
    assert Release.newer?(release, current())
  end

  test "public release metadata encodes timestamps at the DeviceState boundary" do
    published_at = ~U[2026-01-01 00:00:00Z]

    {:ok, release} =
      Release.from_manifest(
        manifest(),
        "https://example.invalid/nerves_gate.fw",
        published_at
      )

    public = Release.public(release)

    assert public.published_at == "2026-01-01T00:00:00Z"
    assert NervesGate.DeviceState.public?(public)
  end

  test "rejects a changed manifest, unknown key, unsafe artifact, and wrong system", keys do
    contents = Jason.encode!(manifest()) <> "\n"
    signature = :crypto.sign(:eddsa, :none, contents, [keys.private_key, :ed25519])
    encoded_signature = Base.encode64(signature)

    assert {:error, :invalid_manifest_signature} =
             Manifest.verify(contents <> " ", encoded_signature, [Base.encode64(keys.public_key)])

    {unknown_public, _unknown_private} = :crypto.generate_key(:eddsa, :ed25519)

    assert {:error, :invalid_manifest_signature} =
             Manifest.verify(contents, encoded_signature, [Base.encode64(unknown_public)])

    assert {:error, :invalid_manifest} =
             Release.from_manifest(
               Map.put(manifest(), "artifact", "../escape.fw"),
               "https://example.invalid/escape.fw"
             )

    {:ok, wrong_system} =
      manifest()
      |> Map.put("system", "other_system")
      |> Release.from_manifest("https://example.invalid/nerves_gate.fw")

    refute Release.compatible?(wrong_system, current())
  end

  defp current do
    %{
      product: "nerves_gate",
      system: "nerves_system_nerves_gate",
      platform: "x86_64",
      architecture: "x86_64",
      version: "1.0.0",
      uuid: "old"
    }
  end

  defp manifest do
    %{
      "schema" => Release.schema(),
      "product" => "nerves_gate",
      "system" => "nerves_system_nerves_gate",
      "platform" => "x86_64",
      "architecture" => "x86_64",
      "version" => "2.0.0",
      "uuid" => "new-firmware",
      "vcs_identifier" => "0123456789abcdef",
      "artifact" => "nerves_gate.fw",
      "size" => 1024,
      "sha256" => String.duplicate("a", 64)
    }
  end
end
