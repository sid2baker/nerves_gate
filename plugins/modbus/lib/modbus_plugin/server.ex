defmodule ModbusPlugin.Server do
  @moduledoc "A raw four-table map. Remote writes change coils/holding; local puts may change any range."
  use GenServer, restart: :temporary
  @behaviour Modbus.Server
  alias ModbusPlugin.{Connection, Protocol}
  @tables Map.new(Protocol.tables(), &{Protocol.function(&1), &1})

  def start_link(config),
    do:
      GenServer.start_link(__MODULE__, config,
        name: {:via, Registry, {ModbusPlugin.Registry, config.id}}
      )

  def put(id, range_id, values) do
    case Connection.pid(id) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:put, range_id, values})
    end
  end

  @impl Modbus.Server
  def handle_request(unit, request, owner), do: GenServer.call(owner, {:request, unit, request})

  @impl GenServer
  def init(config) do
    Process.flag(:trap_exit, true)

    case Modbus.Server.start_link([handler: {__MODULE__, self()}] ++ transport_options(config)) do
      {:ok, server} ->
        map =
          for range <- config.ranges,
              {value, offset} <- Enum.with_index(range.initial),
              into: %{},
              do: {{range.table, range.address + offset}, value}

        {:ok, %{config: config, server: server, map: map}}

      {:error, reason} ->
        {:stop, {:server_start_failed, reason}}
    end
  end

  @doc false
  def transport_options(%{transport: "rtu"} = c),
    do: [
      rtu: c.serial_path,
      units: [c.unit],
      speed: c.speed,
      data_bits: 8,
      stop_bits: c.stop_bits,
      parity: c.parity
    ]

  def transport_options(c), do: [port: c.port, handler_timeout: c.timeout]

  @impl GenServer
  def handle_call(:status, _, state) do
    values =
      Map.new(state.config.ranges, fn range ->
        {range.id,
         for(offset <- 0..(range.count - 1), do: state.map[{range.table, range.address + offset}])}
      end)

    {:reply, %{state: :serving, values: values, error: nil}, state}
  end

  def handle_call({:write, _, _}, _, state), do: {:reply, {:error, :client_required}, state}

  def handle_call({:put, id, values}, _, state) do
    case Enum.find(state.config.ranges, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :unknown_range}, state}

      range ->
        if Protocol.valid_values?(range, values),
          do: {:reply, :ok, store(state, range.table, range.address, values)},
          else: {:reply, {:error, :invalid_raw_values}, state}
    end
  end

  def handle_call({:request, unit, _}, _, %{config: %{unit: own}} = state) when unit != own,
    do: {:reply, {:error, {:exception, :gateway_path_unavailable}}, state}

  def handle_call({:request, _, {function, address, count}}, _, state)
      when is_map_key(@tables, function) do
    table = @tables[function]

    if is_integer(count) and count in 1..Protocol.limit(table) do
      keys = for offset <- 0..(count - 1), do: {table, address + offset}

      if Enum.all?(keys, &Map.has_key?(state.map, &1)),
        do: {:reply, {:ok, Enum.map(keys, &state.map[&1])}, state},
        else: exception(state, :illegal_data_address)
    else
      exception(state, :illegal_data_value)
    end
  end

  def handle_call({:request, _, {:write_single_coil, address, value}}, _, state),
    do: write(state, :coil, address, [value])

  def handle_call({:request, _, {:write_single_register, address, value}}, _, state),
    do: write(state, :holding, address, [value])

  def handle_call({:request, _, {:write_multiple_coils, address, values}}, _, state),
    do: write(state, :coil, address, values)

  def handle_call({:request, _, {:write_multiple_registers, address, values}}, _, state),
    do: write(state, :holding, address, values)

  def handle_call({:request, _, {:read_device_identification, category, from}}, _, state) do
    objects = [
      {0, "Nerves Gate"},
      {1, "modbus_plugin"},
      {2, Application.spec(:modbus_plugin, :vsn) |> to_string()}
    ]

    if category in [:basic, :regular, :extended],
      do:
        {:reply,
         {:ok,
          %{
            conformity_level: 1,
            more_follows: false,
            next_object_id: 0,
            objects: Enum.filter(objects, fn {id, _} -> id >= from end)
          }}, state},
      else: exception(state, :illegal_data_value)
  end

  def handle_call({:request, _, :report_server_id}, _, state),
    do: {:reply, {:ok, <<1, 255, "Nerves Gate Modbus">>}, state}

  def handle_call({:request, _, _}, _, state), do: exception(state, :illegal_function)

  @impl GenServer
  def handle_info({:EXIT, server, reason}, %{server: server} = state),
    do: {:stop, {:server_exit, reason}, state}

  def handle_info(_, state), do: {:noreply, state}
  @impl GenServer
  def terminate(_, state) do
    if Process.alive?(state.server), do: Modbus.Server.stop(state.server)
    :ok
  end

  defp write(state, table, address, values) when is_list(values) do
    range = %{table: table, count: length(values)}

    cond do
      range.count not in 1..Protocol.write_limit(table) or
          not Protocol.valid_values?(range, values) ->
        exception(state, :illegal_data_value)

      not Enum.all?(0..(range.count - 1), &Map.has_key?(state.map, {table, address + &1})) ->
        exception(state, :illegal_data_address)

      true ->
        {:reply, :ok, store(state, table, address, values)}
    end
  end

  defp write(state, _, _, _), do: exception(state, :illegal_data_value)

  defp store(state, table, address, values) do
    entries =
      for {value, offset} <- Enum.with_index(values),
          into: %{},
          do: {{table, address + offset}, value}

    %{state | map: Map.merge(state.map, entries)}
  end

  defp exception(state, reason), do: {:reply, {:error, {:exception, reason}}, state}
end
