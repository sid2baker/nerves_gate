defmodule NervesGate.IO.Catalog do
  @moduledoc false
  # Persisted input/output definitions only; no Desires, Readings or Authority.
  # Invalid saved definitions are rejected and kept untouched.
  alias NervesGate.IO.Definition
  alias NervesGate.Settings
  alias NervesGateSDK.Package

  @key ["io", "definitions"]
  @endpoints 1024

  def load do
    definitions = Settings.get(@key, %{})
    if valid?(definitions), do: {:ok, definitions}, else: {:error, :invalid_io_catalog}
  end

  def save(definitions) do
    cond do
      not valid?(definitions) -> {:error, :io_catalog_full}
      Settings.put(@key, definitions) == :ok -> :ok
      true -> {:error, :io_catalog_write_failed}
    end
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
