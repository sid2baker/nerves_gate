defmodule NervesGate.Firmware.Release do
  @moduledoc "Validated, signed GitHub Release firmware description."

  @schema "nerves_gate.firmware.v1"

  @type t :: %__MODULE__{
          id: String.t(),
          version: String.t(),
          uuid: String.t(),
          product: String.t(),
          system: String.t(),
          platform: String.t(),
          architecture: String.t(),
          vcs_identifier: String.t(),
          artifact: String.t(),
          asset_url: String.t(),
          size: pos_integer(),
          sha256: String.t(),
          published_at: DateTime.t() | nil
        }

  @enforce_keys [
    :id,
    :version,
    :uuid,
    :product,
    :system,
    :platform,
    :architecture,
    :vcs_identifier,
    :artifact,
    :asset_url,
    :size,
    :sha256
  ]
  defstruct @enforce_keys ++ [published_at: nil]

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec from_manifest(map(), String.t(), DateTime.t() | nil) :: {:ok, t()} | {:error, atom()}
  def from_manifest(manifest, asset_url, published_at \\ nil) do
    with :ok <- require_schema(manifest),
         {:ok, version} <- binary(manifest, "version"),
         {:ok, _parsed} <- Version.parse(version),
         {:ok, uuid} <- safe_identifier(manifest, "uuid"),
         {:ok, product} <- safe_identifier(manifest, "product"),
         {:ok, system} <- binary(manifest, "system"),
         {:ok, platform} <- binary(manifest, "platform"),
         {:ok, architecture} <- binary(manifest, "architecture"),
         {:ok, vcs_identifier} <- binary(manifest, "vcs_identifier"),
         {:ok, artifact} <- safe_artifact(manifest),
         {:ok, size} <- positive_integer(manifest, "size"),
         {:ok, sha256} <- sha256(manifest),
         true <- valid_url?(asset_url) do
      {:ok,
       %__MODULE__{
         id: uuid,
         version: version,
         uuid: uuid,
         product: product,
         system: system,
         platform: platform,
         architecture: architecture,
         vcs_identifier: vcs_identifier,
         artifact: artifact,
         asset_url: asset_url,
         size: size,
         sha256: sha256,
         published_at: published_at
       }}
    else
      false -> {:error, :invalid_asset_url}
      {:error, _reason} = error -> error
    end
  end

  @spec compatible?(t(), map()) :: boolean()
  def compatible?(%__MODULE__{} = release, current) do
    release.product == value(current, :product) and
      release.system == value(current, :system) and
      release.platform == value(current, :platform) and
      release.architecture == value(current, :architecture)
  end

  @spec newer?(t(), map()) :: boolean()
  def newer?(%__MODULE__{} = release, current) do
    case Version.parse(value(current, :version)) do
      {:ok, current_version} ->
        Version.compare(Version.parse!(release.version), current_version) == :gt

      :error ->
        false
    end
  end

  @spec public(t()) :: map()
  def public(%__MODULE__{} = release) do
    %{
      id: release.id,
      version: release.version,
      uuid: release.uuid,
      product: release.product,
      system: release.system,
      platform: release.platform,
      architecture: release.architecture,
      vcs_identifier: release.vcs_identifier,
      size: release.size,
      published_at: encode(release.published_at)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = release) do
    release
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), encode(value)} end)
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, atom()}
  def from_map(map) when is_map(map) do
    from_manifest(
      Map.put(map, "schema", @schema),
      Map.get(map, "asset_url", ""),
      parse_datetime(Map.get(map, "published_at"))
    )
  end

  def from_map(_value), do: {:error, :invalid_release}

  defp require_schema(%{"schema" => @schema}), do: :ok
  defp require_schema(_manifest), do: {:error, :unsupported_manifest_schema}

  defp binary(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _invalid -> {:error, :invalid_manifest}
    end
  end

  defp safe_identifier(map, key) do
    with {:ok, value} <- binary(map, key),
         true <- String.match?(value, ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/) do
      {:ok, value}
    else
      _invalid -> {:error, :invalid_manifest}
    end
  end

  defp safe_artifact(map) do
    with {:ok, value} <- binary(map, "artifact"),
         true <- value == Path.basename(value),
         true <- String.ends_with?(value, ".fw"),
         true <- byte_size(value) <= 255 do
      {:ok, value}
    else
      _invalid -> {:error, :invalid_manifest}
    end
  end

  defp positive_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, :invalid_manifest}
    end
  end

  defp sha256(map) do
    with {:ok, digest} <- binary(map, "sha256"),
         true <- String.match?(digest, ~r/\A[0-9a-f]{64}\z/) do
      {:ok, digest}
    else
      _invalid -> {:error, :invalid_manifest}
    end
  end

  defp valid_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["https", "http"] and is_binary(host) ->
        true

      _invalid ->
        false
    end
  end

  defp valid_url?(_value), do: false

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key), "")
  defp encode(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode(value), do: value

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
