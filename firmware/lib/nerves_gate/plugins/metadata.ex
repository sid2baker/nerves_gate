defmodule NervesGate.Plugins.Metadata do
  @moduledoc "Current-only artifact catalog and atomic selection persistence."
  alias NervesGateSDK.Package
  @limit 4 * 1024 * 1024

  def read(file) do
    with {:ok, %{type: :regular, size: size}} when size <= @limit <- File.lstat(file),
         {:ok, <<131, tag, _::binary>> = bytes} when tag != 80 <- File.read(file),
         {%{schema: 2, entries: entries} = metadata, used} <-
           :erlang.binary_to_term(bytes, [:safe, :used]),
         true <- used == byte_size(bytes) and map_size(metadata) == 2 and valid?(entries) do
      {:ok, entries}
    else
      {:error, :enoent} -> {:ok, %{}}
      _ -> {:error, :invalid_app_metadata}
    end
  rescue
    ArgumentError -> {:error, :invalid_app_metadata}
  end

  def persist(file, entries) do
    if valid?(entries) do
      bytes = :erlang.term_to_binary(%{schema: 2, entries: entries})
      if byte_size(bytes) <= @limit, do: write(file, bytes), else: {:error, :invalid_app_metadata}
    else
      {:error, :invalid_app_metadata}
    end
  end

  @doc false
  def write(file, bytes) do
    temp = file <> ".#{Base.encode16(:crypto.strong_rand_bytes(12))}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         {:ok, io} <- File.open(temp, [:write, :exclusive, :binary]) do
      try do
        with :ok <- File.chmod(temp, 0o600),
             :ok <- :file.write(io, bytes),
             :ok <- :file.sync(io),
             :ok <- File.rename(temp, file) do
          sync_directory(Path.dirname(file))
        end
      after
        File.close(io)
        File.rm(temp)
      end
    end
  end

  @doc false
  def sync_directory(path) do
    case :prim_file.open(String.to_charlist(path), [:read, :directory]) do
      {:ok, directory} ->
        try do
          commit_synced(:prim_file.sync(directory))
        after
          :prim_file.close(directory)
        end

      _ ->
        {:error, :metadata_commit_unknown}
    end
  end

  defp commit_synced(:ok), do: :ok
  defp commit_synced(_), do: {:error, :metadata_commit_unknown}

  def valid?(entries) when is_map(entries) and map_size(entries) <= 64,
    do: Enum.all?(entries, &valid_entry?/1)

  def valid?(_), do: false

  defp valid_entry?(
         {app,
          %{
            enabled: enabled,
            active_version: _,
            previous_version: _,
            artifacts: _,
            generation: generation
          } = entry}
       ) do
    map_size(entry) == 5 and is_binary(app) and Package.valid_name?(app) and
      is_boolean(enabled) and is_integer(generation) and generation >= 0 and
      valid_selection?(entry)
  end

  defp valid_entry?(_), do: false

  defp valid_selection?(entry) do
    artifacts = entry.artifacts

    is_map(artifacts) and map_size(artifacts) in 1..256 and
      Enum.all?(artifacts, &valid_artifact?/1) and Map.has_key?(artifacts, entry.active_version) and
      (entry.previous_version == nil or Map.has_key?(artifacts, entry.previous_version))
  end

  defp valid_artifact?(
         {version, %{sha256: sha, source: source, names: names, modules: modules} = artifact}
       ) do
    map_size(artifact) == 4 and source in [:firmware, :development] and
      Package.valid_version?(version) and digest?(sha) and
      bounded_names?(names, 256, &Package.valid_name?/1) and names != [] and
      bounded_names?(modules, 10_000, &(byte_size(&1) in 1..255))
  end

  defp valid_artifact?(_), do: false

  defp digest?(sha), do: is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{64}\z/, sha)

  defp bounded_names?(names, limit, predicate) when is_list(names) do
    Enum.count_until(names, limit + 1) <= limit and
      Enum.all?(names, &(is_binary(&1) and predicate.(&1))) and
      names == Enum.sort(Enum.uniq(names))
  end

  defp bounded_names?(_, _, _), do: false
end
