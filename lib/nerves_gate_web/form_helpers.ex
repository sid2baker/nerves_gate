defmodule NervesGateWeb.FormHelpers do
  @moduledoc false

  @spec blank_to_nil(String.t() | nil) :: String.t() | nil
  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  @spec format_error(term()) :: String.t()
  def format_error(reason) when is_atom(reason) do
    reason |> to_string() |> String.replace("_", " ")
  end

  def format_error(reason) when is_map(reason) do
    Enum.map_join(reason, ", ", fn {field, message} -> "#{field} #{message}" end)
  end

  def format_error(_reason), do: "operation failed"
end
