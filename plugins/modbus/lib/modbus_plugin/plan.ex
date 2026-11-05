defmodule ModbusPlugin.Plan do
  @moduledoc """
  The read requests of one poll. Read mappings of the same table are merged into
  one request while the gap between them is at most the connection's `max_gap`
  unmapped addresses and the request stays within the protocol limit (125
  registers, 2000 bits). The default gap of 0 merges only adjacent or
  overlapping points, because many devices refuse a read that touches an
  unmapped address and would fail every point of the batch.
  """
  alias ModbusPlugin.Codec

  @tables [
    coil: {:read_coils, 2000},
    discrete: {:read_discrete_inputs, 2000},
    holding: {:read_holding_registers, 125},
    input: {:read_input_registers, 125}
  ]

  def tables, do: Keyword.keys(@tables)
  def function(table), do: elem(@tables[table], 0)
  def limit(table), do: elem(@tables[table], 1)

  @doc "Batches `%{table, address, count, mappings}` in address order."
  def build(config) do
    config.mappings
    |> Enum.filter(&(&1.access == :read))
    |> Enum.sort_by(&{&1.table, &1.address})
    |> Enum.reduce([], &add(&1, &2, config.max_gap))
    |> Enum.reverse()
    |> Enum.map(&%{&1 | mappings: Enum.reverse(&1.mappings)})
  end

  def request(batch), do: {function(batch.table), batch.address, batch.count}

  @doc "Decoded `{mapping, {:ok, value} | {:error, reason}}` for each mapping of a batch."
  def decode(batch, values) do
    for mapping <- batch.mappings do
      slice = Enum.slice(values, mapping.address - batch.address, Codec.size(mapping))
      {mapping, Codec.decode(mapping, slice)}
    end
  end

  defp add(mapping, [batch | rest] = batches, max_gap) do
    last = mapping.address + Codec.size(mapping) - 1
    count = max(last, batch.address + batch.count - 1) - batch.address + 1

    if mapping.table == batch.table and mapping.address <= batch.address + batch.count + max_gap and
         count <= limit(batch.table),
       do: [%{batch | count: count, mappings: [mapping | batch.mappings]} | rest],
       else: [new(mapping) | batches]
  end

  defp add(mapping, [], _), do: [new(mapping)]

  defp new(mapping),
    do: %{
      table: mapping.table,
      address: mapping.address,
      count: Codec.size(mapping),
      mappings: [mapping]
    }
end
