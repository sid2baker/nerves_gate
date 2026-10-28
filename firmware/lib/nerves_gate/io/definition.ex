defmodule NervesGate.IO.Definition do
  @moduledoc false
  alias NervesGateSDK.IO.{InputDefinition, OutputDefinition}

  def valid?(
        %InputDefinition{id: _, type: _, unit: _, expected_interval_ms: interval} =
          definition
      ) do
    map_size(definition) == 5 and common?(definition) and
      (interval == nil or (is_integer(interval) and interval > 0))
  end

  def valid?(
        %OutputDefinition{
          id: _,
          type: _,
          unit: _,
          min: _,
          max: _,
          feedback_input_id: _
        } = definition
      ) do
    map_size(definition) == 7 and common?(definition) and bounds?(definition) and
      (definition.feedback_input_id == nil or local_id?(definition.feedback_input_id))
  end

  def valid?(_), do: false

  def local_id?(id) do
    is_binary(id) and byte_size(id) in 1..128 and
      Regex.match?(~r/\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*\z/, id)
  end

  def value?(:boolean, value), do: is_boolean(value)
  def value?(:integer, value), do: is_integer(value)
  def value?(:float, value), do: is_float(value)
  def value?(:string, value), do: text?(value, 0, 1024)
  def value?(_, _), do: false

  def desired?(definition, value) do
    value?(definition.type, value) and
      (definition.min == nil or value >= definition.min) and
      (definition.max == nil or value <= definition.max)
  end

  def observation?(definition, value, :good), do: value?(definition.type, value)
  def observation?(_, nil, quality) when quality in [:invalid, :unknown], do: true
  def observation?(_, _, _), do: false

  def stale?(%InputDefinition{expected_interval_ms: nil}, _, _), do: false
  def stale?(_, nil, _), do: false

  def stale?(definition, observation, now),
    do: now - observation.received_at_ms > definition.expected_interval_ms

  defp common?(definition) do
    local_id?(definition.id) and definition.type in [:boolean, :integer, :float, :string] and
      (definition.unit == nil or text?(definition.unit, 1, 32))
  end

  defp text?(value, min, max),
    do: is_binary(value) and byte_size(value) in min..max and String.valid?(value)

  defp bounds?(%{type: type, min: min, max: max}) when type in [:integer, :float] do
    (min == nil or value?(type, min)) and (max == nil or value?(type, max)) and
      (min == nil or max == nil or min <= max)
  end

  defp bounds?(definition), do: definition.min == nil and definition.max == nil
end
