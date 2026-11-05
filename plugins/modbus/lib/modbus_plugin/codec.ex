defmodule ModbusPlugin.Codec do
  @moduledoc """
  Wire representation of one validated mapping: how many registers or bits it
  occupies and how raw words or bits become a platform value and back.

  Coils and discrete inputs are single booleans. Register types are `bool`
  (word non-zero, or one `bit` of the word), `u16`, `s16`, `u32`, `s32`,
  `float32` and `ascii` (`length` registers, two bytes each, high byte first,
  ended by the first NUL; trailing spaces are dropped). 32-bit values span two
  registers in `word_order` `:high_first` or `:low_first`.

  Integer types publish `raw * scale`: an integer for integer scales and a float,
  rounded to the scale's decimals, otherwise. `float32` publishes the shortest
  float that round-trips the register value, times the scale. A value is only
  encoded when it reads back as exactly that value, so desired values and
  readback compare equal.
  """

  # Published values use the shortest float32-round-trip decimal, including bounds.
  @f32_max 3.4028235e38
  @ranges %{
    u16: {0, 65_535},
    s16: {-32_768, 32_767},
    u32: {0, 4_294_967_295},
    s32: {-2_147_483_648, 2_147_483_647}
  }

  def types, do: [:bool, :u16, :s16, :u32, :s32, :float32, :ascii]
  def bit_table?(table), do: table in [:coil, :discrete]

  @doc "Registers (or bits) the mapping occupies, starting at its address."
  def size(%{type: :ascii, length: length}), do: length
  def size(%{type: type}) when type in [:u32, :s32, :float32], do: 2
  def size(_), do: 1

  def endpoint_type(%{type: :bool}), do: :boolean
  def endpoint_type(%{type: :ascii}), do: :string
  def endpoint_type(%{type: :float32}), do: :float
  def endpoint_type(%{scale: scale}) when is_integer(scale), do: :integer
  def endpoint_type(_), do: :float

  @doc "Raw bits or words of exactly `size/1` into a platform value."
  def decode(%{table: table}, [bit]) when table in [:coil, :discrete], do: {:ok, bit}

  def decode(%{type: :bool} = mapping, [word]) do
    case Map.get(mapping, :bit) do
      nil -> {:ok, word != 0}
      bit -> {:ok, Bitwise.band(Bitwise.bsr(word, bit), 1) == 1}
    end
  end

  def decode(%{type: :ascii}, words) do
    [text | _] = :binary.split(for(word <- words, into: <<>>, do: <<word::16>>), <<0>>)
    text = String.trim_trailing(text, " ")
    if String.printable?(text), do: {:ok, text}, else: {:error, :invalid_text}
  end

  def decode(%{type: :float32} = mapping, words) do
    case binary(mapping, words) do
      <<value::float-32>> -> {:ok, shortest(value) |> times(mapping.scale)}
      _ -> {:error, :not_a_number}
    end
  end

  def decode(%{type: type} = mapping, words) do
    raw =
      case {type, binary(mapping, words)} do
        {:u16, <<v::16>>} -> v
        {:s16, <<v::signed-16>>} -> v
        {:u32, <<v::32>>} -> v
        {:s32, <<v::signed-32>>} -> v
      end

    {:ok, scaled(raw, mapping.scale)}
  end

  @doc "A platform value into raw bits or words, or `:invalid_value` when it does not fit exactly."
  def encode(mapping, value) do
    {min, max} = bounds(mapping)

    if min != nil and (not is_number(value) or value < min or value > max) do
      invalid()
    else
      with {:ok, raw} <- raw(mapping, value) do
        if decode(mapping, raw) == {:ok, value}, do: {:ok, raw}, else: invalid()
      end
    end
  end

  defp raw(%{table: table}, value) when table in [:coil, :discrete] and is_boolean(value),
    do: {:ok, [value]}

  defp raw(%{type: :bool, table: table} = mapping, value)
       when table in [:holding, :input] and is_boolean(value) do
    if Map.get(mapping, :bit) == nil,
      do: {:ok, [if(value, do: 1, else: 0)]},
      else: {:error, :invalid_value}
  end

  defp raw(%{type: :ascii, length: length}, value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= 2 * length do
      padded = value <> :binary.copy(<<0>>, 2 * length - byte_size(value))
      {:ok, for(<<word::16 <- padded>>, do: word)}
    else
      {:error, :invalid_value}
    end
  end

  defp raw(%{type: :float32} = mapping, value) when is_float(value) do
    raw = value / mapping.scale
    if abs(raw) <= @f32_max, do: {:ok, words(<<raw::float-32>>, mapping)}, else: invalid()
  end

  defp raw(%{type: type} = mapping, value) when is_map_key(@ranges, type) do
    {min, max} = @ranges[type]

    with {:ok, raw} <- unscaled(endpoint_type(mapping), value, mapping.scale),
         true <- raw in min..max do
      size = if type in [:u16, :s16], do: 16, else: 32
      {:ok, words(<<raw::size(size)>>, mapping)}
    else
      _ -> invalid()
    end
  end

  defp raw(_, _), do: invalid()

  @doc "Platform output bounds in published units."
  def bounds(%{type: type} = mapping) when is_map_key(@ranges, type) do
    {min, max} = @ranges[type]
    Enum.min_max([scaled(min, mapping.scale), scaled(max, mapping.scale)])
  end

  def bounds(%{type: :float32, scale: scale}),
    do: {-@f32_max * abs(scale) * 1.0, @f32_max * abs(scale) * 1.0}

  def bounds(_), do: {nil, nil}

  @doc "Operator text into a value of the mapping's platform type; other text stays as given."
  def parse(mapping, text) when is_binary(text) do
    text = String.trim(text)

    case {endpoint_type(mapping), Integer.parse(text), Float.parse(text)} do
      {:boolean, _, _} when text in ["true", "false"] -> text == "true"
      {:integer, {value, ""}, _} -> value
      {:float, _, {value, ""}} -> value
      {:string, _, _} -> text
      _ -> text
    end
  end

  defp invalid, do: {:error, :invalid_value}

  defp binary(mapping, words) do
    words = if mapping.word_order == :low_first, do: Enum.reverse(words), else: words
    for word <- words, into: <<>>, do: <<word::16>>
  end

  defp words(binary, mapping) do
    words = for <<word::16 <- binary>>, do: word
    if mapping.word_order == :low_first, do: Enum.reverse(words), else: words
  end

  defp unscaled(:integer, value, scale) when is_integer(value) and rem(value, scale) == 0,
    do: {:ok, div(value, scale)}

  defp unscaled(:float, value, scale) when is_float(value), do: {:ok, round(value / scale)}
  defp unscaled(_, _, _), do: :error

  defp scaled(raw, scale) when is_integer(scale), do: raw * scale
  defp scaled(raw, scale), do: Float.round(raw * scale, decimals(scale))

  defp times(value, 1), do: value
  defp times(value, scale), do: value * scale

  # The shortest decimal that is the same float32, so 12.3 reads back as 12.3.
  defp shortest(value) do
    Enum.find_value(1..9, value, fn digits ->
      {candidate, ""} = Float.parse(:erlang.float_to_binary(value, [{:scientific, digits - 1}]))
      if <<candidate::float-32>> == <<value::float-32>>, do: candidate
    end)
  end

  defp decimals(scale) do
    [mantissa | exponent] =
      scale |> abs() |> :erlang.float_to_binary([:short]) |> String.split("e")

    fraction =
      case String.split(mantissa, ".") do
        [_, "0"] -> 0
        [_, digits] -> byte_size(digits)
      end

    shift = if exponent == [], do: 0, else: String.to_integer(hd(exponent))
    min(15, max(0, fraction - shift))
  end
end
