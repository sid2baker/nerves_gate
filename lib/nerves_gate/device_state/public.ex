defmodule NervesGate.DeviceState.Public do
  @moduledoc "Validates values crossing the shared DeviceState boundary."

  alias NervesGate.DeviceState.Secret

  @spec public?(term()) :: boolean()
  def public?(%Secret{}), do: false
  def public?(value) when is_pid(value) or is_port(value) or is_reference(value), do: false
  def public?(value) when is_function(value), do: false
  def public?(value) when is_binary(value) or is_number(value) or is_atom(value), do: true
  def public?(value) when is_list(value), do: Enum.all?(value, &public?/1)
  def public?(%_module{} = value), do: value |> Map.from_struct() |> public?()

  def public?(value) when is_map(value) do
    Enum.all?(value, fn {key, item} -> public_key?(key) and public?(item) end)
  end

  # IPv4 addresses are encoded as strings at HTTP boundaries. No other tuple
  # can leave a node through DeviceState.
  def public?({a, b, c, d})
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
      do: true

  def public?(_value), do: false

  defp public_key?(key) when is_atom(key) or is_binary(key), do: true
  defp public_key?(_key), do: false
end
