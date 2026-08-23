defmodule NervesGate.Storage do
  @moduledoc """
  Generic durable file and JSON operations under the gateway data directory.
  """

  @type validator(result) :: (map() -> {:ok, result} | {:error, term()})

  @spec root() :: Path.t()
  def root, do: Application.fetch_env!(:nerves_gate, :data_dir)

  @spec path(String.t() | [String.t()], Path.t()) :: Path.t()
  def path(relative, root \\ root())
  def path(relative, root) when is_binary(relative), do: Path.join(root, relative)
  def path(parts, root) when is_list(parts), do: Path.join([root | parts])

  @spec initialize(Path.t()) :: :ok | {:error, term()}
  def initialize(root \\ root()) do
    probe = path(".write-probe", root)

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- write(probe, "ok") do
      File.rm(probe)
    end
  end

  @spec read_json(Path.t(), validator(result), result) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def read_json(path, validator, missing) do
    case File.read(path) do
      {:ok, contents} ->
        with {:ok, decoded} <- Jason.decode(contents),
             {:ok, valid} <- validator.(decoded) do
          {:ok, valid}
        else
          {:error, reason} -> {:error, {:invalid, reason}}
        end

      {:error, :enoent} ->
        {:ok, missing}

      {:error, reason} ->
        {:error, {:read_failed, Path.basename(path), reason}}
    end
  end

  @spec write_json(Path.t(), map(), keyword()) :: :ok | {:error, term()}
  def write_json(path, value, options \\ []) do
    with {:ok, json} <- Jason.encode(value, pretty: true) do
      write(path, json <> "\n", options)
    end
  end

  @spec quarantine(Path.t()) :: :ok | {:error, term()}
  def quarantine(path) do
    case File.rename(path, "#{path}.corrupt-#{System.system_time(:millisecond)}") do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  @doc "Writes a file with a same-filesystem rename so power loss preserves the old file."
  @spec write(Path.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def write(path, contents, options \\ []) do
    directory = Path.dirname(path)
    temporary = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"
    mode = Keyword.get(options, :mode, 0o600)

    with :ok <- File.mkdir_p(directory),
         {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]),
         :ok <- write_sync_close(file, contents),
         :ok <- File.chmod(temporary, mode),
         :ok <- File.rename(temporary, path) do
      sync_directory(directory)
    else
      {:error, reason} = error ->
        File.rm(temporary)
        if reason == :eexist, do: write(path, contents, options), else: error
    end
  end

  @spec replace(Path.t(), Path.t()) :: :ok | {:error, term()}
  def replace(source, destination) do
    directory = Path.dirname(destination)

    if Path.dirname(source) == directory do
      with :ok <- File.rename(source, destination) do
        sync_directory(directory)
      end
    else
      {:error, :cross_device_replace}
    end
  end

  defp write_sync_close(file, contents) do
    result =
      case :file.write(file, contents) do
        :ok -> :file.sync(file)
        {:error, _reason} = error -> error
      end

    File.close(file)
    result
  end

  # Directory fsync is supported by the target filesystem. Some host filesystems
  # reject opening directories; the data file itself has still been synced there.
  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :raw]) do
      {:ok, handle} ->
        result = :file.sync(handle)
        :file.close(handle)
        result

      {:error, reason} when reason in [:eisdir, :eacces] ->
        :ok

      {:error, reason} ->
        {:error, {:directory_sync, reason}}
    end
  end
end
