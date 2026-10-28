defmodule NervesGate.Storage.Config do
  @moduledoc """
  One opaque configuration term per plugin version, stored as
  `<plugin data dir>/.nerves_gate/config/<version>.term`.

  Saves replace the file atomically through `NervesGate.Plugins.Metadata.write/2`;
  a failed save leaves the previous term or none. Restores refuse atoms/functions
  unknown to the running system, compressed or trailing data and files over 1 MiB.
  Corrupt files are reported, never removed. Other versions' files are untouched.
  There is no migration, merging or schema: the plugin owns the term.
  """
  alias NervesGate.Plugins.Metadata
  alias NervesGateSDK.Package

  @limit 1_048_576

  def save(data, version, term) do
    bytes = :erlang.term_to_binary(term)

    with true <- byte_size(bytes) <= @limit or {:error, :configuration_too_large},
         {:ok, file} <- file(data, version) do
      case Metadata.write(file, bytes) do
        {:error, :metadata_commit_unknown} -> {:error, :commit_unknown}
        result -> result
      end
    end
  end

  def restore(data, version) do
    with {:ok, file} <- file(data, version),
         {:ok, %{type: :regular, size: size}} when size <= @limit <- File.lstat(file),
         {:ok, bytes} <- File.read(file),
         {term, used} when used == byte_size(bytes) <- decode(bytes) do
      {:ok, term}
    else
      {:error, :enoent} -> :not_found
      {:error, :invalid_version} = error -> error
      _ -> {:error, :invalid_configuration}
    end
  end

  def delete(data, version) do
    with {:ok, file} <- file(data, version),
         {:ok, %{type: :regular}} <- File.lstat(file),
         :ok <- File.rm(file) do
      case Metadata.sync_directory(Path.dirname(file)) do
        :ok -> :ok
        _ -> {:error, :commit_unknown}
      end
    else
      {:error, :enoent} -> :not_found
      {:ok, _} -> {:error, :invalid_configuration}
      error -> error
    end
  end

  defp file(data, version) do
    with true <- Package.valid_version?(version) or {:error, :invalid_version},
         {:ok, private} <- NervesGate.Storage.directory(data, ".nerves_gate"),
         {:ok, config} <- NervesGate.Storage.directory(private, "config") do
      {:ok, Path.join(config, version <> ".term")}
    end
  end

  # Removable media: no new atoms/funs, compressed terms or trailing bytes.
  defp decode(<<131, tag, _::binary>> = bytes) when tag != 80 do
    :erlang.binary_to_term(bytes, [:safe, :used])
  rescue
    ArgumentError -> :invalid
  end

  defp decode(_), do: :invalid
end
