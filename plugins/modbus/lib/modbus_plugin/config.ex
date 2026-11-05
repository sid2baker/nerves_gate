defmodule ModbusPlugin.Config do
  @moduledoc "Validate saved transports and bounded raw ranges, without opening anything."
  alias ModbusPlugin.Protocol

  @id ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @host ~r/\A[a-zA-Z0-9.:%_-]+\z/
  @speeds [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115_200]
  @keys ~w(id role transport host port serial_port authorized speed parity stop_bits unit interval timeout ranges)

  def speeds, do: @speeds

  def validate(id, params) when is_map(params) do
    role = choice(params["role"], [:client, :server])
    transport = params["transport"] || "tcp"

    config = %{
      id: id,
      role: role,
      transport: transport,
      host: if(transport == "tcp" and role == :client, do: params["host"]),
      port: if(transport == "tcp", do: integer(params["port"])),
      serial_port: if(transport == "rtu", do: params["serial_port"]),
      authorized: transport == "rtu" and params["authorized"] in [true, "true"],
      speed: if(transport == "rtu", do: integer(params["speed"])),
      parity: if(transport == "rtu", do: choice(params["parity"], [:none, :even, :odd])),
      stop_bits: if(transport == "rtu", do: integer(params["stop_bits"])),
      unit: integer(params["unit"]),
      interval: if(role == :client, do: integer(params["interval"])),
      timeout: integer(params["timeout"]),
      ranges: []
    }

    with :ok <- known_keys(params, @keys),
         :ok <- check(valid_id?(id), "id", id),
         :ok <- check(role != nil, "role", params["role"]),
         :ok <- transport(config, params),
         :ok <- check(config.unit in 1..247, "unit", params["unit"]),
         :ok <- check(config.timeout in 100..5000, "timeout", params["timeout"]),
         :ok <-
           check(role != :client or config.interval in 100..60000, "interval", params["interval"]),
         {:ok, ranges} <- ranges(role, params["ranges"]) do
      {:ok, %{config | ranges: ranges}}
    end
  end

  def validate(_, params), do: {:error, {:invalid_field, "params", params}}

  def params(config) do
    config
    |> Map.take(Enum.map(@keys, &String.to_existing_atom/1))
    |> Map.new(fn
      {:ranges, ranges} ->
        {"ranges", Enum.map(ranges, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))}

      {k, v} ->
        {Atom.to_string(k), v}
    end)
  end

  defp transport(%{transport: "tcp", role: role} = c, params) do
    with :ok <-
           check(
             role == :server or
               (is_binary(c.host) and byte_size(c.host) in 1..253 and Regex.match?(@host, c.host)),
             "host",
             params["host"]
           ),
         do: check(c.port in 1..65535, "port", params["port"])
  end

  defp transport(%{transport: "rtu"} = c, params) do
    with :ok <-
           check(
             is_binary(c.serial_port) and byte_size(c.serial_port) in 1..32 and
               c.serial_port =~ ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/,
             "serial_port",
             params["serial_port"]
           ),
         :ok <- check(c.authorized, "authorized", params["authorized"]),
         :ok <- check(c.speed in @speeds, "speed", params["speed"]),
         :ok <- check(c.parity != nil, "parity", params["parity"]),
         do: check(c.stop_bits in [1, 2], "stop_bits", params["stop_bits"])
  end

  defp transport(_, params), do: {:error, {:invalid_field, "transport", params["transport"]}}

  defp ranges(role, list) when is_list(list) and length(list) <= 64 do
    with :ok <- check(role == :client or list != [], "ranges", list) do
      list
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {params, index}, {:ok, acc} ->
        label = if is_map(params), do: params["id"] || index, else: index

        case range(role, params) do
          {:ok, range} ->
            cond do
              Enum.any?(acc, &(&1.id == range.id)) ->
                {:halt, {:error, {:invalid_range, label, :duplicate_id}}}

              Enum.any?(acc, &overlap?(&1, range)) ->
                {:halt, {:error, {:invalid_range, label, :overlap}}}

              range.count + Enum.sum(Enum.map(acc, & &1.count)) > 4096 ->
                {:halt, {:error, {:invalid_field, "ranges", :address_limit}}}

              true ->
                {:cont, {:ok, [range | acc]}}
            end

          {:error, reason} ->
            {:halt, {:error, {:invalid_range, label, reason}}}
        end
      end)
      |> then(fn
        {:ok, ranges} -> {:ok, Enum.reverse(ranges)}
        error -> error
      end)
    end
  end

  defp ranges(_, list), do: {:error, {:invalid_field, "ranges", list}}

  defp range(role, params) when is_map(params) do
    keys = ~w(id table address count) ++ if(role == :client, do: ["writable"], else: ["initial"])
    table = choice(params["table"], Protocol.tables())
    address = integer(params["address"])
    count = integer(params["count"])

    with :ok <- known_keys(params, keys),
         :ok <- check(valid_id?(params["id"]), "id", params["id"]),
         :ok <- check(table != nil, "table", params["table"]),
         :ok <- check(address in 0..65535, "address", params["address"]),
         :ok <-
           check(
             is_integer(count) and count in 1..Protocol.limit(table),
             "count",
             params["count"]
           ),
         :ok <- check(address + count - 1 <= 65535, "span", {address, count}) do
      range = %{id: params["id"], table: table, address: address, count: count}
      range_options(role, range, params)
    end
  end

  defp range(_, _), do: {:error, :not_an_object}

  defp range_options(:client, range, params) do
    writable = params["writable"] in [true, "true"]
    limit = Protocol.write_limit(range.table)

    with :ok <-
           check(
             params["writable"] in [nil, false, true, "false", "true"],
             "writable",
             params["writable"]
           ),
         :ok <-
           check(
             not writable or (limit != nil and range.count <= limit),
             "writable",
             :unsupported_table_or_count
           ) do
      {:ok, Map.put(range, :writable, writable)}
    end
  end

  defp range_options(:server, range, params) do
    initial =
      if is_nil(params["initial"]),
        do: List.duplicate(if(Protocol.bits?(range.table), do: false, else: 0), range.count),
        else: params["initial"]

    with :ok <- check(Protocol.valid_values?(range, initial), "initial", initial),
         do: {:ok, Map.put(range, :initial, initial)}
  end

  defp overlap?(a, b),
    do: a.table == b.table and a.address < b.address + b.count and b.address < a.address + a.count

  defp valid_id?(id), do: is_binary(id) and Regex.match?(@id, id)

  defp known_keys(params, keys) do
    case Enum.find(Map.keys(params), &(&1 not in keys)) do
      nil -> :ok
      key -> {:error, {:unknown_field, key}}
    end
  end

  defp check(true, _, _), do: :ok
  defp check(_, field, value), do: {:error, {:invalid_field, field, value}}

  defp choice(value, allowed),
    do: Enum.find(allowed, &(value == &1 or value == Atom.to_string(&1)))

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp integer(_), do: nil
end
