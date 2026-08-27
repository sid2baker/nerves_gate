defmodule NervesGate.Firmware.GitHubTest do
  use ExUnit.Case, async: true

  alias NervesGate.Firmware.ReleaseSource.GitHub

  test "selects only a newer compatible release whose manifest signature is valid" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    manifest = Jason.encode!(manifest()) <> "\n"
    signature = :crypto.sign(:eddsa, :none, manifest, [private_key, :ed25519]) |> Base.encode64()

    releases =
      Jason.encode!([
        %{
          "draft" => false,
          "prerelease" => false,
          "published_at" => "2026-01-01T00:00:00Z",
          "assets" => [
            asset("nerves_gate.firmware.json", "https://download.invalid/manifest"),
            asset("nerves_gate.firmware.json.sig", "https://download.invalid/signature"),
            asset("nerves_gate.fw", "https://download.invalid/firmware")
          ]
        }
      ])

    get = fn url, _headers, _options ->
      case url do
        "https://api.invalid/repos/owner/repository/releases?per_page=20" -> {:ok, releases}
        "https://download.invalid/manifest" -> {:ok, manifest}
        "https://download.invalid/signature" -> {:ok, signature}
      end
    end

    assert {:ok, release} =
             GitHub.latest(current(),
               repository: "owner/repository",
               api_url: "https://api.invalid",
               manifest_public_keys: [Base.encode64(public_key)],
               http_get: get
             )

    assert release.version == "2.0.0"
    assert release.asset_url == "https://download.invalid/firmware"
  end

  test "does not expose unsigned release metadata as an available update" do
    releases =
      Jason.encode!([
        %{
          "draft" => false,
          "prerelease" => false,
          "assets" => [
            asset("nerves_gate.firmware.json", "https://download.invalid/manifest"),
            asset("nerves_gate.firmware.json.sig", "https://download.invalid/signature"),
            asset("nerves_gate.fw", "https://download.invalid/firmware")
          ]
        }
      ])

    get = fn url, _headers, _options ->
      if String.contains?(url, "/releases?"), do: {:ok, releases}, else: {:ok, "invalid"}
    end

    assert {:ok, nil} =
             GitHub.latest(current(),
               repository: "owner/repository",
               api_url: "https://api.invalid",
               manifest_public_keys: [Base.encode64(:crypto.strong_rand_bytes(32))],
               http_get: get
             )
  end

  defp asset(name, url), do: %{"name" => name, "browser_download_url" => url}

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
      "schema" => "nerves_gate.firmware.v1",
      "product" => "nerves_gate",
      "system" => "nerves_system_nerves_gate",
      "platform" => "x86_64",
      "architecture" => "x86_64",
      "version" => "2.0.0",
      "uuid" => "new",
      "vcs_identifier" => "new-revision",
      "artifact" => "nerves_gate.fw",
      "size" => 1024,
      "sha256" => String.duplicate("a", 64)
    }
  end
end
