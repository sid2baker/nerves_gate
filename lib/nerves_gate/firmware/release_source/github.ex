defmodule NervesGate.Firmware.ReleaseSource.GitHub do
  @moduledoc "Discovers compatible signed manifests and artifacts from GitHub Releases."

  @behaviour NervesGate.Firmware.ReleaseSource

  alias NervesGate.Firmware.{HTTP, Manifest, Release}

  @impl true
  def latest(current, options) do
    http_get = Keyword.get(options, :http_get, &HTTP.get/3)
    repository = Keyword.fetch!(options, :repository)
    api_url = Keyword.get(options, :api_url, "https://api.github.com")
    channel = Keyword.get(options, :channel, :stable)
    keys = Keyword.get(options, :manifest_public_keys, [])
    http_options = Keyword.take(options, [:allow_insecure_http, :timeout])

    releases_url =
      "#{String.trim_trailing(api_url, "/")}/repos/#{repository}/releases?per_page=20"

    with {:ok, body} <- get(http_get, releases_url, api_headers(), http_options, 2 * 1024 * 1024),
         {:ok, releases} <- Jason.decode(body),
         true <- is_list(releases) do
      releases
      |> Enum.reject(&Map.get(&1, "draft", true))
      |> Enum.filter(&channel_release?(&1, channel))
      |> Enum.reduce(
        [],
        &collect_candidate(&1, &2, current, keys, http_get, http_options)
      )
      |> newest()
    else
      false -> {:error, :invalid_release_response}
      {:error, _reason} = error -> error
    end
  end

  defp collect_candidate(release, candidates, current, keys, http_get, http_options) do
    case release_candidate(release, current, keys, http_get, http_options) do
      {:ok, candidate} -> [candidate | candidates]
      {:error, _reason} -> candidates
    end
  end

  defp release_candidate(release, current, keys, http_get, http_options) do
    assets = Map.get(release, "assets", [])

    with %{"name" => manifest_name, "browser_download_url" => manifest_url} <-
           Enum.find(assets, &manifest_asset?/1),
         %{"browser_download_url" => signature_url} <-
           Enum.find(assets, &(Map.get(&1, "name") == manifest_name <> ".sig")),
         {:ok, manifest_contents} <- get(http_get, manifest_url, [], http_options, 64 * 1024),
         {:ok, signature} <- get(http_get, signature_url, [], http_options, 1024),
         {:ok, manifest} <- Manifest.verify(manifest_contents, signature, keys),
         %{"browser_download_url" => asset_url} <-
           Enum.find(assets, &(Map.get(&1, "name") == Map.get(manifest, "artifact"))),
         {:ok, candidate} <- Release.from_manifest(manifest, asset_url, published_at(release)),
         true <- Release.compatible?(candidate, current),
         true <- Release.newer?(candidate, current),
         true <- candidate.uuid != value(current, :uuid) do
      {:ok, candidate}
    else
      nil -> {:error, :incomplete_release}
      false -> {:error, :incompatible_release}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_release}
    end
  end

  defp get(http_get, url, headers, options, maximum) do
    http_get.(url, headers, Keyword.put(options, :maximum_size, maximum))
  end

  defp manifest_asset?(%{"name" => name}) when is_binary(name),
    do: String.ends_with?(name, ".firmware.json")

  defp manifest_asset?(_asset), do: false

  defp channel_release?(release, :stable), do: Map.get(release, "prerelease", true) == false
  defp channel_release?(_release, :prerelease), do: true
  defp channel_release?(_release, _channel), do: false

  defp newest([]), do: {:ok, nil}

  defp newest(candidates) do
    {:ok, Enum.max_by(candidates, &Version.parse!(&1.version), Version)}
  end

  defp published_at(%{"published_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> nil
    end
  end

  defp published_at(_release), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp api_headers do
    [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]
  end
end
