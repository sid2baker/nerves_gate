defmodule NervesGate.AtomicFile do
  @moduledoc """
  Writes files with a same-filesystem rename so power loss preserves the old file.
  """

  @spec write(Path.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def write(path, contents, opts \\ []) do
    directory = Path.dirname(path)
    temporary = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"
    mode = Keyword.get(opts, :mode, 0o600)

    with :ok <- File.mkdir_p(directory),
         {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]),
         :ok <- write_sync_close(file, contents),
         :ok <- File.chmod(temporary, mode),
         :ok <- File.rename(temporary, path) do
      sync_directory(directory)
    else
      {:error, reason} = error ->
        File.rm(temporary)
        if reason == :eexist, do: write(path, contents, opts), else: error
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

      {:error, :eisdir} ->
        :ok

      {:error, :eacces} ->
        :ok

      {:error, reason} ->
        {:error, {:directory_sync, reason}}
    end
  end
end
