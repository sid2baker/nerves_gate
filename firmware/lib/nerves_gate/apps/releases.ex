defmodule NervesGate.Apps.Releases do
  @moduledoc "First-party public GitHub app releases. Fixed origin, bounded reads, no background updates or credentials."
  alias NervesGate.Apps.Artifact
  alias NervesGateSDK.Package
  @repo "sid2baker/nerves_gate"
  @apps [%{app: "tailnet_subrouter", name: "Tailnet subnet router"}]
  @archive_limit 16 * 1024 * 1024
  @metadata_limit 2 * 1024 * 1024

  def repository, do: @repo
  def applications, do: @apps

  def tag(app, version), do: "apps/#{app}/v#{version}"
  def archive(app, version), do: "#{app}-#{version}.ez"
  def manifest_name(app, version), do: "#{app}-#{version}.json"

  def approved?(app), do: Enum.any?(@apps, &(&1.app == app))

  def valid_version?(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, %{build: nil}} -> true
      _ -> false
    end
  end

  def valid_version?(_), do: false

  def available(options \\ []) do
    with {:ok, body} <-
           fetch(
             "https://api.github.com/repos/#{@repo}/releases?per_page=100",
             @metadata_limit,
             options
           ),
         {:ok, releases} when is_list(releases) <- decode(body),
         true <- Enum.count_until(releases, 101) <= 100 do
      {:ok, latest(releases)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_release_metadata}
    end
  end

  @doc false
  def latest(releases) do
    for %{app: app, name: name} <- @apps,
        release =
          Enum.filter(releases, &listed?(&1, app))
          |> Enum.max_by(&version(&1, app), Version, fn -> nil end),
        release != nil do
      %{
        app: app,
        name: name,
        version: version(release, app),
        prerelease?: release["prerelease"] == true
      }
    end
  end

  defp version(release, app), do: String.replace_prefix(release["tag_name"], "apps/#{app}/v", "")

  defp listed?(%{"tag_name" => tag, "draft" => false} = release, app) when is_binary(tag) do
    prefix = "apps/#{app}/v"

    String.starts_with?(tag, prefix) and valid_version?(version(release, app)) and
      assets?(release, app, version(release, app))
  end

  defp listed?(_, _), do: false

  defp assets?(%{"assets" => assets}, app, version) when is_list(assets) do
    Enum.all?([archive(app, version), manifest_name(app, version)], fn name ->
      Enum.count(assets, &(is_map(&1) and &1["name"] == name and &1["state"] == "uploaded")) == 1
    end)
  end

  defp assets?(_, _, _), do: false

  def review(app, version, options \\ []) do
    with true <- approved?(app) and valid_version?(version),
         {:ok, bytes} <-
           fetch(asset_url(app, version, manifest_name(app, version)), 64 * 1024, options),
         {:ok, manifest} <- decode(bytes),
         :ok <- validate(manifest, app, version),
         :ok <- compatible(manifest) do
      {:ok, manifest}
    else
      false -> {:error, :unknown_app_release}
      {:error, reason} -> {:error, reason}
    end
  end

  def download(manifest, options \\ []) do
    app = manifest["app"]
    version = manifest["version"]

    with :ok <- validate(manifest, app, version),
         :ok <- compatible(manifest),
         {:ok, bytes} <-
           fetch(asset_url(app, version, manifest["archive"]), manifest["size"], options),
         true <-
           byte_size(bytes) == manifest["size"] and Artifact.hash(bytes) == manifest["sha256"],
         {:ok, package} <- Package.read_binary(bytes),
         {:ok, expected} <- describe(package, bytes, manifest["source_revision"]),
         true <- expected == manifest do
      {:ok, package, bytes, manifest["sha256"]}
    else
      false -> {:error, :release_integrity_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Pure manifest generation for the release preparer. No files or network effects."
  def describe(package, bytes, revision) do
    manifest = %{
      "schema" => 1,
      "app" => to_string(package.app),
      "version" => package.version,
      "archive" => archive(package.app, package.version),
      "sha256" => Artifact.hash(bytes),
      "size" => byte_size(bytes),
      "sdk" => package.main.env[:nerves_gate_sdk_requirement],
      "platform" =>
        Enum.map(package.main.env[:nerves_gate_platform] || [], fn {name, version} ->
          [to_string(name), version]
        end)
        |> Enum.sort(),
      "otp" => to_string(:erlang.system_info(:otp_release)),
      "elixir" => System.version(),
      "targets" => ["ec100", "x86_64"],
      "source_revision" => revision
    }

    with :ok <- validate(manifest, manifest["app"], package.version),
         true <-
           match?([_], package.apps) and
             Enum.all?(package.files, fn {path, _} ->
               String.ends_with?(path, [".beam", ".app"])
             end) do
      {:ok, manifest}
    else
      false -> {:error, :unsupported_release_payload}
      error -> error
    end
  rescue
    _ -> {:error, :invalid_release_metadata}
  end

  def validate(manifest, app, version) when is_map(manifest) do
    valid =
      map_size(manifest) == 12 and manifest["schema"] == 1 and
        identity?(manifest, app, version) and integrity?(manifest) and runtime?(manifest) and
        valid_platform?(manifest["platform"])

    if valid, do: :ok, else: {:error, :invalid_release_metadata}
  end

  def validate(_, _, _), do: {:error, :invalid_release_metadata}

  defp identity?(manifest, app, version) do
    approved?(app) and manifest["app"] == app and valid_version?(version) and
      manifest["version"] == version and manifest["archive"] == archive(app, version)
  end

  defp integrity?(manifest) do
    digest?(manifest["sha256"], 64) and digest?(manifest["source_revision"], 40) and
      is_integer(manifest["size"]) and manifest["size"] in 1..@archive_limit
  end

  defp runtime?(manifest) do
    is_binary(manifest["sdk"]) and match?({:ok, _}, Version.parse_requirement(manifest["sdk"])) and
      manifest["targets"] == ["ec100", "x86_64"] and is_binary(manifest["otp"]) and
      Regex.match?(~r/\A[0-9]{1,3}\z/, manifest["otp"]) and valid_version?(manifest["elixir"])
  end

  defp decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, :invalid_release_metadata}
    end
  end

  defp digest?(value, size),
    do: is_binary(value) and byte_size(value) == size and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp valid_platform?(platform) when is_list(platform) do
    Enum.count_until(platform, 65) <= 64 and
      Enum.all?(platform, fn
        [app, version] ->
          is_binary(app) and Package.valid_name?(app) and is_binary(version) and
            Package.valid_version?(version)

        _ ->
          false
      end) and platform == Enum.sort(Enum.uniq_by(platform, &hd/1))
  end

  defp valid_platform?(_), do: false

  def compatible(manifest) do
    installed =
      Map.new(Application.loaded_applications(), fn {app, _, version} ->
        {to_string(app), to_string(version)}
      end)

    target = to_string(Application.get_env(:nerves_gate, :target, :host))

    cond do
      target not in manifest["targets"] ->
        {:error, :incompatible_release_target}

      manifest["otp"] != to_string(:erlang.system_info(:otp_release)) or
          manifest["elixir"] != System.version() ->
        {:error, :incompatible_release_runtime}

      not Version.match?(to_string(Application.spec(:nerves_gate_sdk, :vsn)), manifest["sdk"]) ->
        {:error, :incompatible_sdk}

      not Enum.all?(manifest["platform"], fn [app, version] -> installed[app] == version end) ->
        {:error, :incompatible_platform_dependency}

      true ->
        :ok
    end
  rescue
    _ -> {:error, :incompatible_release_runtime}
  end

  defp asset_url(app, version, file) do
    encoded = URI.encode(tag(app, version), &URI.char_unreserved?/1)
    "https://github.com/#{@repo}/releases/download/#{encoded}/#{file}"
  end

  @doc false
  def allowed_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: 443, userinfo: nil, fragment: nil} ->
        host in [
          "api.github.com",
          "github.com",
          "release-assets.githubusercontent.com",
          "objects.githubusercontent.com"
        ]

      _ ->
        false
    end
  end

  defp fetch(url, limit, options),
    do: fetch(url, limit, options, 3, System.monotonic_time(:millisecond) + 45_000)

  defp fetch(url, limit, options, redirects, deadline) do
    if allowed_url?(url) and redirects >= 0 and System.monotonic_time(:millisecond) < deadline do
      callback = fn {:data, chunk}, pair -> stream_chunk(chunk, pair, limit, deadline) end
      remaining = max(deadline - System.monotonic_time(:millisecond), 1)

      request_options = [
        url: url,
        retry: false,
        redirect: false,
        decode_body: false,
        compressed: false,
        connect_options: [timeout: min(10_000, remaining)],
        receive_timeout: min(10_000, remaining),
        request_timeout: remaining,
        headers: [
          {"user-agent", "nerves-gate-app-releases"},
          {"accept",
           if(URI.parse(url).host == "api.github.com",
             do: "application/vnd.github+json",
             else: "application/octet-stream"
           )}
        ],
        into: callback
      ]

      result = Req.get(Keyword.merge(request_options, Keyword.take(options, [:plug])))
      response(result, url, limit, options, redirects, deadline)
    else
      {:error, :release_fetch_failed}
    end
  rescue
    _ -> {:error, :release_fetch_failed}
  catch
    :exit, _ -> {:error, :release_fetch_failed}
  end

  defp stream_chunk(chunk, {request, response}, limit, deadline) do
    size = Map.get(request.private, :release_size, 0) + byte_size(chunk)
    count = Map.get(request.private, :release_chunks, 0) + 1

    if size <= limit and count <= 16_384 and System.monotonic_time(:millisecond) < deadline do
      request =
        request
        |> Req.Request.put_private(:release_size, size)
        |> Req.Request.put_private(:release_chunks, count)

      chunks = if count == 1, do: [chunk], else: [chunk | response.body]
      {:cont, {request, %{response | body: chunks}}}
    else
      {:halt, {request, %{response | status: 413, body: []}}}
    end
  end

  defp response({:ok, %{status: 200, body: body}}, _, limit, _, _, _) do
    if IO.iodata_length(body) <= limit,
      do: {:ok, IO.iodata_to_binary(if(is_list(body), do: Enum.reverse(body), else: body))},
      else: {:error, :release_fetch_failed}
  end

  defp response({:ok, %{status: status} = response}, url, limit, options, redirects, deadline)
       when status in [301, 302, 303, 307, 308] do
    case Req.Response.get_header(response, "location") do
      [location] ->
        fetch(
          URI.merge(url, location) |> URI.to_string(),
          limit,
          options,
          redirects - 1,
          deadline
        )

      _ ->
        {:error, :release_fetch_failed}
    end
  end

  defp response({:ok, %{status: 404}}, _, _, _, _, _), do: {:error, :release_not_published}

  defp response({:ok, %{status: status}}, _, _, _, _, _) when status in [403, 429],
    do: {:error, :release_rate_limited}

  defp response(_, _, _, _, _, _), do: {:error, :release_fetch_failed}
end
