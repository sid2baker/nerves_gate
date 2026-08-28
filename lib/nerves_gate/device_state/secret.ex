defmodule NervesGate.DeviceState.Secret do
  @moduledoc """
  Redacted marker for private values that must never cross DeviceState.

  Public validation rejects this marker recursively, and inspection never
  renders its wrapped value.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t(value) :: %__MODULE__{value: value}

  @spec new(value) :: t(value) when value: term()
  def new(value), do: %__MODULE__{value: value}

  @spec unwrap(t(value)) :: value when value: term()
  def unwrap(%__MODULE__{value: value}), do: value

  @doc false
  @spec contains?(term()) :: boolean()
  def contains?(%__MODULE__{}), do: true
  def contains?(value) when is_list(value), do: Enum.any?(value, &contains?/1)
  def contains?(%_{} = value), do: value |> Map.from_struct() |> contains?()

  def contains?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} -> contains?(key) or contains?(item) end)
  end

  def contains?(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.any?(&contains?/1)
  end

  def contains?(_value), do: false
end

defimpl Inspect, for: NervesGate.DeviceState.Secret do
  import Inspect.Algebra

  @impl true
  def inspect(_secret, _options), do: concat(["#Secret<redacted>"])
end
