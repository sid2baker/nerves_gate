defmodule ModbusPlugin.Config do
  @moduledoc """
  Bounded validation of one saved client or server definition. Validation never
  resolves ports or opens anything, and every refusal names what is wrong:
  `{:invalid_field, field, value}` for the connection and
  `{:invalid_mapping, id_or_position, reason}` for a mapping.

  Addresses are zero-based protocol addresses (the number sent on the wire),
  not 1-based register numbers such as `30001` or `40001`. Mapping IDs identify
  stable equipment meaning and become the plugin-local SDK endpoint IDs
  `<connection>.<mapping>`; a changed meaning needs a new ID.

  Client mappings read any of the four tables (`coil`, `discrete`, `holding`,
  `input`); only `coil` and `holding` accept `access: "write"`. Server mappings
  expose points of all four tables and must not overlap. See `ModbusPlugin.Codec`
  for types, scale and word order.
  """
  alias ModbusPlugin.{Codec, Plan}

  @id ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @host ~r/\A[a-zA-Z0-9.:%_-]+\z/
  @speeds [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115_200]
  @max_mappings 64
  @client_keys ~w(id table address access type scale unit word_order bit length feedback)
  @server_keys ~w(id table address type scale unit word_order length initial)
  @numeric [:u16, :s16, :u32, :s32, :float32]

  def speeds, do: @speeds

  def validate(id, params) when is_map(params) do
    role = choice(params["role"], [:client, :server], nil)
    transport = params["transport"] || "tcp"
    client? = role == :client

    config = %{
      id: id,
      role: role,
      transport: transport,
      host: if(transport == "tcp" and client?, do: params["host"]),
      port: if(transport == "tcp", do: integer(params["port"])),
      serial_port: if(transport == "rtu", do: params["serial_port"]),
      authorized: transport == "rtu" and params["authorized"] in [true, "true"],
      speed: if(transport == "rtu", do: integer(params["speed"])),
      parity: if(transport == "rtu", do: choice(params["parity"], [:none, :even, :odd], nil)),
      stop_bits: if(transport == "rtu", do: integer(params["stop_bits"])),
      unit: integer(params["unit"]),
      interval: if(client?, do: integer(params["interval"])),
      timeout: integer(params["timeout"]),
      max_gap: if(client?, do: integer(params["max_gap"] || 0)),
      mappings: []
    }

    with :ok <- check(is_binary(id) and Regex.match?(@id, id), "id", id),
         :ok <- check(role != nil, "role", params["role"]),
         :ok <- transport(config, params),
         :ok <- check(config.unit in 1..247, "unit", params["unit"]),
         :ok <- check(config.timeout in 100..5_000, "timeout", params["timeout"]),
         :ok <- check(!client? or config.interval in 100..60_000, "interval", params["interval"]),
         :ok <- check(!client? or config.max_gap in 0..100, "max_gap", params["max_gap"]),
         {:ok, mappings} <- mappings(role, params["mappings"]) do
      {:ok, %{config | mappings: mappings}}
    end
  end

  def validate(id, _), do: {:error, {:invalid_field, "params", id}}

  @doc "Params with string keys that validate back to this exact config."
  def params(config) do
    Map.new(config, fn
      {:mappings, mappings} ->
        {"mappings", Enum.map(mappings, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))}

      {key, value} ->
        {Atom.to_string(key), value}
    end)
  end

  defp transport(%{transport: "tcp", role: role} = config, params) do
    with :ok <-
           check(
             role == :server or
               (is_binary(config.host) and byte_size(config.host) in 1..253 and
                  Regex.match?(@host, config.host)),
             "host",
             params["host"]
           ),
         do: check(config.port in 1..65535, "port", params["port"])
  end

  defp transport(%{transport: "rtu"} = config, params) do
    with :ok <-
           check(
             is_binary(config.serial_port) and byte_size(config.serial_port) in 1..32 and
               config.serial_port =~ ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/,
             "serial_port",
             params["serial_port"]
           ),
         :ok <- check(config.authorized, "authorized", params["authorized"]),
         :ok <- check(config.speed in @speeds, "speed", params["speed"]),
         :ok <- check(config.parity != nil, "parity", params["parity"]),
         do: check(config.stop_bits in [1, 2], "stop_bits", params["stop_bits"])
  end

  defp transport(_, params), do: {:error, {:invalid_field, "transport", params["transport"]}}

  defp mappings(:client, []), do: {:ok, []}

  defp mappings(role, list) when is_list(list) and length(list) in 1..@max_mappings do
    with {:ok, mappings} <- each(list, role),
         :ok <- unique(mappings),
         :ok <- overlaps(role, mappings),
         do: feedback(mappings)
  end

  defp mappings(_, list), do: {:error, {:invalid_field, "mappings", count(list)}}

  defp count(list) when is_list(list), do: length(list)
  defp count(other), do: other

  defp each(list, role) do
    list
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {params, position}, {:ok, acc} ->
      label = if is_map(params) and is_binary(params["id"]), do: params["id"], else: position

      case mapping(role, params) do
        {:ok, mapping} -> {:cont, {:ok, [mapping | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_mapping, label, reason}}}
      end
    end)
    |> then(fn
      {:ok, mappings} -> {:ok, Enum.reverse(mappings)}
      error -> error
    end)
  end

  defp mapping(role, params) when is_map(params) do
    keys = if role == :client, do: @client_keys, else: @server_keys

    with :ok <- known_keys(params, keys),
         :ok <- reason(is_binary(params["id"]) and Regex.match?(@id, params["id"]), :invalid_id),
         {:ok, table} <- field(params["table"], Plan.tables(), nil, :unsupported_table),
         {:ok, access} <- access(role, table, params["access"]),
         {:ok, type} <- type(table, params["type"]),
         {:ok, mapping} <- point(params, table, type),
         :ok <- span(mapping, params["address"]),
         {:ok, mapping} <- role_fields(role, access, mapping, params) do
      {:ok, mapping}
    end
  end

  defp mapping(_, _), do: {:error, :not_an_object}

  defp known_keys(params, keys) do
    case Enum.find(Map.keys(params), &(&1 not in keys)) do
      nil -> :ok
      key -> {:error, {:unknown_field, key}}
    end
  end

  defp access(:server, _, _), do: {:ok, nil}

  defp access(:client, table, value) do
    with {:ok, access} <- field(value, [:read, :write], :read, :invalid_access) do
      if access == :write and table not in [:coil, :holding],
        do: {:error, {:not_writable, table}},
        else: {:ok, access}
    end
  end

  defp type(table, value) do
    with {:ok, type} <- field(value, Codec.types(), default_type(table), :invalid_type) do
      if Codec.bit_table?(table) and type != :bool,
        do: {:error, {:type_not_allowed, type, table}},
        else: {:ok, type}
    end
  end

  defp default_type(table), do: if(Codec.bit_table?(table), do: :bool, else: :u16)

  defp point(params, table, type) do
    with {:ok, scale} <- scale(type, params["scale"]),
         {:ok, unit} <- unit(params["unit"]),
         {:ok, word_order} <- word_order(type, params["word_order"]),
         {:ok, length} <- ascii_length(type, params["length"]) do
      {:ok,
       %{
         id: params["id"],
         table: table,
         address: integer(params["address"]),
         type: type,
         scale: scale,
         unit: unit,
         word_order: word_order,
         length: length
       }}
    end
  end

  defp scale(type, nil) when type in @numeric, do: {:ok, 1}

  defp scale(type, scale) when type in @numeric and is_number(scale) and scale != 0 do
    if abs(scale) >= 1.0e-6 and abs(scale) <= 1.0e6,
      do: {:ok, scale},
      else: {:error, {:invalid_scale, scale}}
  end

  defp scale(type, scale) when type in @numeric, do: {:error, {:invalid_scale, scale}}
  defp scale(_, nil), do: {:ok, nil}
  defp scale(_, _), do: {:error, {:not_applicable, "scale"}}

  defp unit(nil), do: {:ok, nil}

  defp unit(unit) when is_binary(unit) and byte_size(unit) in 1..32,
    do: if(String.valid?(unit), do: {:ok, unit}, else: {:error, {:invalid_unit, unit}})

  defp unit(unit), do: {:error, {:invalid_unit, unit}}

  defp word_order(type, value) when type in [:u32, :s32, :float32],
    do: field(value, [:high_first, :low_first], :high_first, :invalid_word_order)

  defp word_order(_, nil), do: {:ok, nil}
  defp word_order(_, _), do: {:error, {:not_applicable, "word_order"}}

  defp ascii_length(:ascii, value) do
    case integer(value) do
      length when length in 1..123 -> {:ok, length}
      _ -> {:error, {:invalid_length, value}}
    end
  end

  defp ascii_length(_, nil), do: {:ok, nil}
  defp ascii_length(_, _), do: {:error, {:not_applicable, "length"}}

  defp span(%{address: address} = mapping, given) do
    cond do
      address not in 0..65535 -> {:error, {:address_out_of_range, given}}
      address + Codec.size(mapping) - 1 > 65535 -> {:error, {:span_out_of_range, given}}
      true -> :ok
    end
  end

  defp role_fields(:client, access, mapping, params) do
    with {:ok, bit} <- bit(access, mapping, params["bit"]),
         {:ok, feedback} <- feedback_id(access, params["feedback"]) do
      {:ok, Map.merge(mapping, %{access: access, bit: bit, feedback: feedback})}
    end
  end

  defp role_fields(:server, _, mapping, params) do
    with {:ok, initial} <- initial(mapping, params["initial"]),
         do: {:ok, Map.put(mapping, :initial, initial)}
  end

  defp bit(_, _, nil), do: {:ok, nil}

  defp bit(:read, %{type: :bool, table: table}, bit) when table in [:holding, :input] do
    if bit in 0..15, do: {:ok, bit}, else: {:error, {:invalid_bit, bit}}
  end

  defp bit(:write, _, _), do: {:error, :bit_is_read_only}
  defp bit(_, _, _), do: {:error, {:not_applicable, "bit"}}

  defp feedback_id(_, value) when value in [nil, ""], do: {:ok, nil}
  defp feedback_id(:write, value) when is_binary(value), do: {:ok, value}
  defp feedback_id(:write, value), do: {:error, {:unknown_feedback, value}}
  defp feedback_id(_, _), do: {:error, {:not_applicable, "feedback"}}

  # A server publishes every point from the start; a missing initial is zero.
  defp initial(mapping, nil), do: initial(mapping, zero(Codec.endpoint_type(mapping)))

  defp initial(mapping, value) do
    value =
      if Codec.endpoint_type(mapping) == :float and is_integer(value) and abs(value) <= 1.0e308,
        do: value * 1.0,
        else: value

    case Codec.encode(mapping, value) do
      {:ok, _} -> {:ok, value}
      {:error, _} -> {:error, {:invalid_initial, value}}
    end
  end

  defp zero(:boolean), do: false
  defp zero(:integer), do: 0
  defp zero(:float), do: 0.0
  defp zero(:string), do: ""

  defp unique(mappings) do
    mappings
    |> Enum.reduce_while(MapSet.new(), fn %{id: id}, seen ->
      if MapSet.member?(seen, id),
        do: {:halt, {:error, {:invalid_mapping, id, :duplicate_id}}},
        else: {:cont, MapSet.put(seen, id)}
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  # Server points and client writes each own their addresses; reads may overlap.
  defp overlaps(role, mappings) do
    owners = if role == :server, do: mappings, else: Enum.filter(mappings, &(&1.access == :write))

    owners
    |> Enum.reduce_while(%{}, fn mapping, taken ->
      keys =
        for offset <- 0..(Codec.size(mapping) - 1), do: {mapping.table, mapping.address + offset}

      case Enum.find_value(keys, &taken[&1]) do
        nil -> {:cont, Map.merge(taken, Map.new(keys, &{&1, mapping.id}))}
        other -> {:halt, {:error, {:invalid_mapping, mapping.id, {:overlaps, other}}}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  # Readback evidence compares equal values, so feedback must publish the same type.
  defp feedback(mappings) do
    reads = for %{access: :read} = m <- mappings, into: %{}, do: {m.id, Codec.endpoint_type(m)}

    Enum.find_value(mappings, {:ok, mappings}, fn
      %{feedback: nil} ->
        nil

      %{feedback: feedback, id: id} = mapping ->
        case reads[feedback] do
          nil ->
            {:error, {:invalid_mapping, id, {:unknown_feedback, feedback}}}

          type ->
            if type == Codec.endpoint_type(mapping),
              do: nil,
              else: {:error, {:invalid_mapping, id, {:incompatible_feedback, feedback}}}
        end

      _ ->
        nil
    end)
  end

  defp check(true, _, _), do: :ok
  defp check(_, field, value), do: {:error, {:invalid_field, field, value}}

  defp reason(true, _), do: :ok
  defp reason(_, reason), do: {:error, reason}

  defp field(value, allowed, default, reason) do
    case choice(value, allowed, default) do
      nil -> {:error, {reason, value}}
      choice -> {:ok, choice}
    end
  end

  # Values arrive as JSON strings from forms and as atoms from a restored config.
  defp choice(nil, _, default), do: default

  defp choice(value, allowed, _) when is_atom(value),
    do: if(value in allowed, do: value)

  defp choice(value, allowed, _) when is_binary(value),
    do: Enum.find(allowed, &(Atom.to_string(&1) == value))

  defp choice(_, _, _), do: nil

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp integer(_), do: nil
end
