defmodule NervesGate.IO.Catalog do
  @moduledoc false
  alias NervesGate.IO.Definition
  alias NervesGate.Plugins.Metadata
  alias NervesGateSDK.Package

  @limit 1024 * 1024
  @endpoints 1024

  def load(path) do
    with {:ok, %{type: :regular, size: size}} when size <= @limit <- File.lstat(path),
         {:ok, <<131, tag, _::binary>> = bytes} when tag != 80 <- File.read(path) do
      decode(bytes)
    else
      {:error, :enoent} -> {:ok, %{}}
      _ -> {:error, :invalid_io_catalog}
    end
  end

  def save(path, definitions) do
    bytes = :erlang.term_to_binary(%{schema: 1, definitions: definitions})

    if valid?(definitions) and byte_size(bytes) <= @limit do
      case Metadata.write(path, bytes) do
        :ok -> :ok
        _ -> {:error, :io_catalog_write_failed}
      end
    else
      {:error, :io_catalog_full}
    end
  end

  defp decode(bytes) do
    case :erlang.binary_to_term(bytes, [:safe, :used]) do
      {%{schema: 1, definitions: definitions} = document, used}
      when map_size(document) == 2 and used == byte_size(bytes) ->
        if valid?(definitions), do: {:ok, definitions}, else: {:error, :invalid_io_catalog}

      _ ->
        {:error, :invalid_io_catalog}
    end
  rescue
    ArgumentError -> {:error, :invalid_io_catalog}
  end

  defp valid?(definitions) when is_map(definitions) and map_size(definitions) <= @endpoints,
    do: Enum.all?(definitions, &entry?/1)

  defp valid?(_), do: false

  defp entry?({id, definition}) when is_binary(id) do
    case String.split(id, ".", parts: 2) do
      [app, local_id] ->
        Package.valid_name?(app) and Definition.valid?(definition) and definition.id == local_id

      _ ->
        false
    end
  end

  defp entry?(_), do: false
end
