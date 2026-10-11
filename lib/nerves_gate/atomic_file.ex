defmodule NervesGate.AtomicFile do
  @moduledoc """
  Crash-safe local writes with explicit commit uncertainty.

  `:not_committed` means replacement did not happen. `:uncertain` means rename
  (or unlink) happened but its directory sync failed. Callers must reconcile an
  uncertain outcome; treating it as an ordinary failed write can undo a commit.
  """

  @callback read(Path.t()) :: {:ok, binary()} | {:error, term()}
  @callback write(Path.t(), binary()) :: :ok | {:error, {:not_committed | :uncertain, term()}}
  @callback remove(Path.t()) :: :ok | {:error, term()}

  def read(path), do: File.read(path)

  def write(path, contents) do
    temporary = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    try do
      with :ok <- ensure_directory(Path.dirname(path)),
           :ok <- write_temporary(temporary, contents),
           :ok <- File.rename(temporary, path) do
        case sync_directory(Path.dirname(path)) do
          :ok -> :ok
          {:error, reason} -> {:error, {:uncertain, reason}}
        end
      else
        {:error, reason} -> {:error, {:not_committed, reason}}
      end
    after
      File.rm(temporary)
    end
  end

  def remove(path) do
    case File.rm(path) do
      :ok -> sync_directory(Path.dirname(path))
      {:error, :enoent} -> sync_directory(Path.dirname(path))
      error -> error
    end
  end

  defp ensure_directory(path) do
    if File.dir?(path) do
      :ok
    else
      with :ok <- ensure_directory(Path.dirname(path)),
           :ok <- File.mkdir(path) do
        sync_directory(Path.dirname(path))
      end
    end
  end

  defp write_temporary(path, contents) do
    with {:ok, file} <- File.open(path, [:write, :exclusive, :binary, :raw]) do
      try do
        with :ok <- File.chmod(path, 0o600),
             :ok <- :file.write(file, contents) do
          :file.sync(file)
        end
      after
        File.close(file)
      end
    end
  end

  defp sync_directory(path) do
    with {:ok, directory} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      try do
        :file.sync(directory)
      after
        :file.close(directory)
      end
    end
  end
end
