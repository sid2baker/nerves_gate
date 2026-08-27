defmodule NervesGate.Firmware.Artifact do
  @moduledoc "Persistent firmware download and cryptographic/metadata verification."

  alias NervesGate.Firmware.{Command, HTTP, Release}
  alias NervesGate.Storage

  @spec download(Release.t(), Path.t(), (non_neg_integer() -> any()), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def download(%Release{} = release, root, progress, options \\ []) do
    partial = partial_path(root, release)
    verified = verified_path(root, release)
    http = Keyword.get(options, :http, HTTP)

    with {:ok, _bytes} <-
           download_with_resume(
             http,
             release,
             partial,
             progress,
             options,
             Keyword.get(options, :download_attempts, 5)
           ),
         :ok <- Storage.replace(partial, verified) do
      {:ok, verified}
    end
  end

  @spec verify(Path.t(), Release.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(path, %Release{} = release, current, options \\ []) do
    keys = Keyword.get(options, :fwup_public_keys, [])
    fwup = Keyword.get(options, :fwup_path, "fwup")
    runner = Keyword.get(options, :runner, &MuonTrap.cmd/3)

    with :ok <- exact_size(path, release.size),
         {:ok, digest} <- digest(path),
         :ok <- compare_digest(digest, release.sha256),
         :ok <- verify_signature(path, keys, fwup, runner, options),
         {:ok, metadata} <- metadata(path, fwup, runner, options),
         :ok <- validate_metadata(metadata, release, current) do
      {:ok, metadata}
    end
  end

  defp download_with_resume(http, release, partial, progress, options, attempts) do
    result =
      http.download(
        release.asset_url,
        partial,
        release.size,
        progress,
        Keyword.take(options, [:allow_insecure_http, :timeout])
      )

    case result do
      {:error, reason} when attempts > 1 ->
        if transient_download_error?(reason) do
          Process.sleep((6 - min(attempts, 5)) * 250)
          download_with_resume(http, release, partial, progress, options, attempts - 1)
        else
          result
        end

      _other ->
        result
    end
  end

  defp transient_download_error?(:download_timeout), do: true
  defp transient_download_error?({:http, status}) when is_integer(status), do: status >= 500
  defp transient_download_error?({:http, _reason}), do: true
  defp transient_download_error?(_reason), do: false

  @spec partial_path(Path.t(), Release.t()) :: Path.t()
  def partial_path(root, %Release{id: id}), do: Path.join([root, "firmware", "#{id}.fw.part"])

  @spec verified_path(Path.t(), Release.t()) :: Path.t()
  def verified_path(root, %Release{id: id}), do: Path.join([root, "firmware", "#{id}.fw"])

  @spec remove(Release.t(), Path.t()) :: :ok
  def remove(%Release{} = release, root) do
    File.rm(partial_path(root, release))
    File.rm(verified_path(root, release))
    :ok
  end

  defp exact_size(path, expected) do
    case File.stat(path) do
      {:ok, %{size: ^expected}} -> :ok
      {:ok, _stat} -> {:error, :artifact_size_mismatch}
      {:error, reason} -> {:error, {:artifact_unavailable, reason}}
    end
  end

  defp digest(path) do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      context = :crypto.hash_init(:sha256)
      result = digest_chunks(file, context)
      File.close(file)
      result
    end
  end

  defp digest_chunks(file, context) do
    case :file.read(file, 1024 * 1024) do
      {:ok, chunk} -> digest_chunks(file, :crypto.hash_update(context, chunk))
      :eof -> {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      {:error, reason} -> {:error, {:artifact_read_failed, reason}}
    end
  end

  defp compare_digest(digest, digest), do: :ok
  defp compare_digest(_actual, _expected), do: {:error, :artifact_digest_mismatch}

  defp verify_signature(_path, [], _fwup, _runner, _options),
    do: {:error, :no_trusted_firmware_keys}

  defp verify_signature(path, keys, fwup, runner, options) do
    args = ["-V", "-i", path] ++ Enum.flat_map(keys, &["--public-key", &1])

    case run_verifier(runner, fwup, args, command_options(options, 60_000)) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {_output, :timeout}} -> {:error, :firmware_signature_timeout}
      {:ok, {_output, _status}} -> {:error, :invalid_firmware_signature}
      {:error, :command_timeout} -> {:error, :firmware_signature_timeout}
      {:error, :command_crashed} -> {:error, :firmware_verifier_unavailable}
    end
  end

  defp metadata(path, fwup, runner, options) do
    case run_verifier(
           runner,
           fwup,
           ["-m", "-i", path],
           command_options(options, 30_000)
         ) do
      {:ok, {output, 0}} -> parse_metadata(IO.iodata_to_binary(output))
      {:ok, {_output, :timeout}} -> {:error, :firmware_metadata_timeout}
      {:ok, {_output, _status}} -> {:error, :invalid_firmware_metadata}
      {:error, :command_timeout} -> {:error, :firmware_metadata_timeout}
      {:error, :command_crashed} -> {:error, :firmware_verifier_unavailable}
    end
  end

  defp run_verifier(runner, executable, arguments, options, attempts \\ 3) do
    case Command.run(runner, executable, arguments, options) do
      {:error, :command_crashed} when attempts > 1 ->
        Process.sleep((4 - attempts) * 250)
        run_verifier(runner, executable, arguments, options, attempts - 1)

      result ->
        result
    end
  end

  defp parse_metadata(output) do
    metadata =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, metadata ->
        case String.split(line, "=", parts: 2) do
          ["meta-" <> key, value] -> Map.put(metadata, key, unquote_value(value))
          _other -> metadata
        end
      end)

    {:ok, metadata}
  end

  defp unquote_value("\"" <> value), do: String.trim_trailing(value, "\"")
  defp unquote_value(value), do: value

  defp validate_metadata(metadata, release, current) do
    expected = %{
      "product" => release.product,
      "version" => release.version,
      "uuid" => release.uuid,
      "platform" => release.platform,
      "architecture" => release.architecture,
      "misc" => release.system,
      "vcs-identifier" => release.vcs_identifier
    }

    cond do
      not Enum.all?(expected, fn {key, value} -> Map.get(metadata, key) == value end) ->
        {:error, :firmware_metadata_mismatch}

      not Release.compatible?(release, current) ->
        {:error, :incompatible_firmware}

      not Release.newer?(release, current) ->
        {:error, :firmware_not_newer}

      release.uuid == value(current, :uuid) ->
        {:error, :firmware_already_installed}

      true ->
        :ok
    end
  end

  defp command_options(options, default_timeout) do
    [
      timeout: Keyword.get(options, :command_timeout, default_timeout),
      stderr_to_stdout: true
    ]
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
