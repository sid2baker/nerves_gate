defmodule ModbusPlugin.Config do
  @moduledoc """
  Bounded validation of one saved client or server definition. Addresses are
  zero-based. Mapping IDs identify stable equipment meaning and become the
  plugin-local SDK endpoint IDs `<connection>.<mapping>`; a changed meaning needs
  a new ID. Validation never resolves ports or opens anything.
  """

  @id ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @host ~r/\A[a-zA-Z0-9.:%_-]+\z/
  @speeds [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115_200]
  @serial_ports ["ttyS3", "ttyS4"]
  @max_mappings 64

  def speeds, do: @speeds
  def serial_ports, do: @serial_ports

  def validate(id, params) when is_binary(id) and is_map(params) do
    role = role(params["role"])
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
      parity: if(transport == "rtu", do: parity(params["parity"])),
      stop_bits: if(transport == "rtu", do: integer(params["stop_bits"])),
      unit: integer(params["unit"]),
      interval: if(role == :client, do: integer(params["interval"])),
      timeout: integer(params["timeout"]),
      mappings: mappings(role, params["mappings"])
    }

    if Regex.match?(@id, id) and role != nil and valid_transport?(config) and
         config.unit in 1..247 and config.timeout in 100..5_000 and
         (role == :server or config.interval in 100..60_000) and
         valid_mappings?(config.mappings) do
      {:ok, config}
    else
      {:error, :invalid_configuration}
    end
  end

  def validate(_, _), do: {:error, :invalid_configuration}

  @doc "Params with string keys that validate back to this exact config."
  def params(config) do
    Map.new(config, fn
      {:mappings, mappings} ->
        {"mappings", Enum.map(mappings, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))}

      {key, value} ->
        {Atom.to_string(key), value}
    end)
  end

  defp valid_transport?(%{transport: "tcp", role: :client, host: host, port: port}),
    do:
      is_binary(host) and byte_size(host) in 1..253 and Regex.match?(@host, host) and
        port in 1..65535

  defp valid_transport?(%{transport: "tcp", role: :server, port: port}), do: port in 1..65535

  defp valid_transport?(%{transport: "rtu"} = config) do
    config.serial_port in @serial_ports and config.authorized and config.speed in @speeds and
      config.parity in [:none, :even, :odd] and config.stop_bits in [1, 2]
  end

  defp valid_transport?(_), do: false

  defp valid_mappings?(mappings)
       when is_list(mappings) and length(mappings) in 1..@max_mappings do
    ids = Enum.map(mappings, & &1[:id])
    inputs = for %{direction: :input} = m <- mappings, into: %{}, do: {m.id, m.table}

    Enum.uniq(ids) == ids and
      Enum.uniq_by(mappings, &{&1[:table], &1[:address], &1[:direction]}) == mappings and
      Enum.all?(mappings, &valid_mapping?(&1, inputs))
  end

  defp valid_mappings?(_), do: false

  defp valid_mapping?(nil, _), do: false

  defp valid_mapping?(%{direction: :observed} = m, _),
    do:
      valid_point?(m) and
        ((m.table == :holding and is_integer(m.initial) and m.initial in 0..65535) or
           (m.table == :coil and is_boolean(m.initial)))

  defp valid_mapping?(%{direction: :input} = m, _), do: valid_point?(m)

  defp valid_mapping?(%{direction: :output} = m, inputs),
    do: valid_point?(m) and (m.feedback == nil or inputs[m.feedback] == m.table)

  defp valid_mapping?(_, _), do: false

  defp valid_point?(m),
    do:
      is_binary(m.id) and Regex.match?(@id, m.id) and m.table in [:holding, :coil] and
        is_integer(m.address) and m.address in 0..65535

  defp mappings(role, mappings) when is_list(mappings) and length(mappings) <= @max_mappings,
    do: Enum.map(mappings, &mapping(role, &1))

  defp mappings(_, _), do: nil

  defp mapping(:server, %{} = m) do
    %{
      id: m["id"],
      table: table(m["table"]),
      address: integer(m["address"]),
      direction: :observed,
      initial: initial(table(m["table"]), m["initial"])
    }
  end

  defp mapping(:client, %{} = m) do
    direction = if m["direction"] in ["output", :output], do: :output, else: :input

    %{
      id: m["id"],
      table: table(m["table"]),
      address: integer(m["address"]),
      direction: direction,
      feedback: if(direction == :output, do: blank_to_nil(m["feedback"]))
    }
  end

  defp mapping(_, _), do: nil

  defp initial(:coil, value) when value in [true, "true"], do: true
  defp initial(:coil, value) when value in [false, "false", nil, ""], do: false
  defp initial(:holding, value), do: integer(value) || 0
  defp initial(_, _), do: nil

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp role("client"), do: :client
  defp role("server"), do: :server
  defp role(:client), do: :client
  defp role(:server), do: :server
  defp role(_), do: nil

  defp parity(value) when value in ["none", :none], do: :none
  defp parity(value) when value in ["even", :even], do: :even
  defp parity(value) when value in ["odd", :odd], do: :odd
  defp parity(_), do: nil

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp integer(_), do: nil
  defp table(value) when value in ["holding", :holding], do: :holding
  defp table(value) when value in ["coil", :coil], do: :coil
  defp table(_), do: nil
end
