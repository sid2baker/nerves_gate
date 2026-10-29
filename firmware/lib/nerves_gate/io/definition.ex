defmodule NervesGate.IO.Definition do
  @moduledoc false
  alias NervesGateSDK.IO.{Evidence, InputDefinition, OutputDefinition}
  alias NervesGateSDK.Package

  @roles [:readback, :physical, :consequence, :estimate]
  @max_evidence 8
  @max_settle_ms 3_600_000

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
          on_release: on_release,
          evidence: evidence
        } = definition
      ) do
    map_size(definition) == 8 and common?(definition) and bounds?(definition) and
      on_release?(definition, on_release) and evidence?(definition, evidence)
  end

  def valid?(_), do: false

  def roles, do: @roles

  def local_id?(id) do
    is_binary(id) and byte_size(id) in 1..128 and
      Regex.match?(~r/\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*\z/, id)
  end

  def full_id?(id) do
    local_id?(id) and
      case String.split(id, ".", parts: 2) do
        [app, _] -> Package.valid_name?(app)
        _ -> false
      end
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

  def reading?(definition, value, :good), do: value?(definition.type, value)
  def reading?(_, nil, quality) when quality in [:invalid, :unknown], do: true
  def reading?(_, _, _), do: false

  def stale?(%InputDefinition{expected_interval_ms: nil}, _, _), do: false
  def stale?(_, nil, _), do: false

  def stale?(definition, reading, now),
    do: now - reading.received_at_ms > definition.expected_interval_ms

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

  defp on_release?(_, nil), do: true
  defp on_release?(_, :hold), do: true
  defp on_release?(definition, {:value, value}), do: desired?(definition, value)
  defp on_release?(_, _), do: false

  defp evidence?(definition, evidence) when is_list(evidence) do
    length(evidence) <= @max_evidence and
      Enum.uniq_by(evidence, &input_of/1) == evidence and
      Enum.all?(evidence, &entry?(definition, &1))
  end

  defp evidence?(_, _), do: false

  defp input_of(%Evidence{input: input}), do: input
  defp input_of(other), do: other

  defp entry?(
         definition,
         %Evidence{input: input, role: role, settle_ms: settle, expect: expect} = entry
       ) do
    map_size(entry) == 5 and full_id?(input) and role in @roles and is_integer(settle) and
      settle in 0..@max_settle_ms and expect?(definition.type, expect)
  end

  defp entry?(_, _), do: false

  defp expect?(_, :equals), do: true

  defp expect?(type, {:tolerance, delta}) when type in [:integer, :float],
    do: is_number(delta) and delta >= 0

  defp expect?(:boolean, conditions) when is_map(conditions) and map_size(conditions) in 1..2,
    do:
      Enum.all?(conditions, fn {desired, condition} ->
        is_boolean(desired) and condition?(condition)
      end)

  defp expect?(_, _), do: false

  defp condition?({bound, number}) when bound in [:above, :below], do: is_number(number)

  defp condition?({:equals, value}),
    do: is_boolean(value) or is_number(value) or text?(value, 0, 1024)

  defp condition?(_), do: false
end
