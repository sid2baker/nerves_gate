defmodule ModbusPlugin.Protocol do
  @moduledoc "Raw Modbus tables, wire limits and requests. No device interpretation."

  @tables [
    coil: {:read_coils, 2000, 1968},
    discrete: {:read_discrete_inputs, 2000, nil},
    holding: {:read_holding_registers, 125, 123},
    input: {:read_input_registers, 125, nil}
  ]

  def tables, do: Keyword.keys(@tables)
  def function(table), do: elem(@tables[table], 0)
  def limit(table), do: elem(@tables[table], 1)
  def write_limit(table), do: elem(@tables[table], 2)
  def bits?(table), do: table in [:coil, :discrete]
  def read(range), do: {function(range.table), range.address, range.count}

  def valid_values?(range, values) do
    is_list(values) and length(values) == range.count and
      Enum.all?(values, fn value ->
        if bits?(range.table),
          do: is_boolean(value),
          else: is_integer(value) and value in 0..65535
      end)
  end

  def write(%{table: :coil, address: address}, [bit]), do: {:write_single_coil, address, bit}
  def write(%{table: :coil, address: address}, bits), do: {:write_multiple_coils, address, bits}

  def write(%{table: :holding, address: address}, [word]),
    do: {:write_single_register, address, word}

  def write(%{table: :holding, address: address}, words),
    do: {:write_multiple_registers, address, words}
end
