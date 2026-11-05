defmodule ModbusPlugin.Server do
  @moduledoc """
  One explicitly started Modbus server exposing exactly the saved mappings of
  all four tables. The runtime process owns the visible raw map: remote masters
  write coils and holding registers, explicit local changes set any mapping, and
  every mapping is published as an ordinary platform input with its decoded
  value. Requests outside the mapped points, and remote writes that leave a
  mapping undecodable, are refused. The library runs each request handler in a
  short-lived process, so handlers only forward to this owner and never touch
  the platform themselves.
  """
  use GenServer, restart: :temporary
  @behaviour Modbus.Server
  alias ModbusPlugin.{Codec, Connection, Endpoint, Plan}

  @tables Map.new(Plan.tables(), &{Plan.function(&1), &1})

  def start_link(config),
    do:
      GenServer.start_link(__MODULE__, config,
        name: {:via, Registry, {ModbusPlugin.Registry, config.id}}
      )

  @doc "Explicitly change one mapped local value; callers never hold the map."
  def put(id, mapping_id, value) do
    case Connection.pid(id) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:put, mapping_id, value})
    end
  end

  @impl Modbus.Server
  def handle_request(unit, request, owner), do: GenServer.call(owner, {:request, unit, request})

  @impl GenServer
  def init(config) do
    Process.flag(:trap_exit, true)

    with :ok <- Endpoint.register(config),
         {:ok, server} <- start_server(config) do
      state = %{config: config, server: server, map: %{}, values: %{}}

      state =
        Enum.reduce(config.mappings, state, fn mapping, state ->
          {:ok, raw} = Codec.encode(mapping, mapping.initial)
          store(state, mapping, mapping.initial, raw)
        end)

      {:ok, publish_all(state, config.mappings)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_server(config) do
    options = [handler: {__MODULE__, self()}] ++ transport_options(config)

    case Modbus.Server.start_link(options) do
      {:ok, server} -> {:ok, server}
      {:error, reason} -> {:error, {:server_start_failed, reason}}
    end
  end

  @doc false
  def transport_options(%{transport: "rtu"} = config) do
    [
      rtu: config.serial_path,
      units: [config.unit],
      speed: config.speed,
      data_bits: 8,
      stop_bits: config.stop_bits,
      parity: config.parity
    ]
  end

  def transport_options(config), do: [port: config.port, handler_timeout: config.timeout]

  @impl GenServer
  def handle_call(:status, _, state),
    do: {:reply, %{state: :serving, values: state.values, error: nil, read_at: nil}, state}

  def handle_call({:put, mapping_id, value}, _, state) do
    with %{} = mapping <- Enum.find(state.config.mappings, &(&1.id == mapping_id)),
         {:ok, raw} <- Codec.encode(mapping, value) do
      {:reply, :ok, publish_all(store(state, mapping, value, raw), [mapping])}
    else
      nil -> {:reply, {:error, :unknown_mapping}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:request, unit, _}, _, %{config: %{unit: own}} = state) when unit != own,
    do: {:reply, {:error, {:exception, :gateway_path_unavailable}}, state}

  def handle_call({:request, _, {function, address, count}}, _, state)
      when is_map_key(@tables, function) do
    keys = for offset <- 0..(count - 1), do: {@tables[function], address + offset}

    if Enum.all?(keys, &Map.has_key?(state.map, &1)),
      do: {:reply, {:ok, Enum.map(keys, &state.map[&1])}, state},
      else: {:reply, {:error, {:exception, :illegal_data_address}}, state}
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

    answer = %{
      conformity_level: 1,
      more_follows: false,
      next_object_id: 0,
      objects: Enum.filter(objects, fn {id, _} -> id >= from end)
    }

    if category in [:basic, :regular, :extended],
      do: {:reply, {:ok, answer}, state},
      else: {:reply, {:error, {:exception, :illegal_data_value}}, state}
  end

  def handle_call({:request, _, :report_server_id}, _, state),
    do: {:reply, {:ok, <<1, 255, "Nerves Gate Modbus">>}, state}

  def handle_call({:request, _, _}, _, state),
    do: {:reply, {:error, {:exception, :illegal_function}}, state}

  @impl GenServer
  def handle_info({:EXIT, server, reason}, %{server: server} = state),
    do: {:stop, {:server_exit, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_, state) do
    if Process.alive?(state.server), do: Modbus.Server.stop(state.server)
    :ok
  end

  # A remote write lands only when every touched address is mapped and every
  # touched mapping still decodes; otherwise nothing changes.
  defp write(state, table, address, values) do
    keys = for {_, offset} <- Enum.with_index(values), do: {table, address + offset}
    map = Map.merge(state.map, Map.new(Enum.zip(keys, values)))
    changed = Enum.filter(state.config.mappings, &(&1.table == table and touches?(&1, keys)))
    decoded = for mapping <- changed, do: {mapping, Codec.decode(mapping, raw(map, mapping))}

    cond do
      not Enum.all?(keys, &Map.has_key?(state.map, &1)) ->
        {:reply, {:error, {:exception, :illegal_data_address}}, state}

      not Enum.all?(decoded, &match?({_, {:ok, _}}, &1)) ->
        {:reply, {:error, {:exception, :illegal_data_value}}, state}

      true ->
        values =
          for {mapping, {:ok, value}} <- decoded, into: state.values, do: {mapping.id, value}

        {:reply, :ok, publish_all(%{state | map: map, values: values}, changed)}
    end
  end

  defp touches?(mapping, keys),
    do:
      Enum.any?(keys, fn {_, a} ->
        a in mapping.address..(mapping.address + Codec.size(mapping) - 1)//1
      end)

  defp raw(map, mapping),
    do:
      for(
        offset <- 0..(Codec.size(mapping) - 1),
        do: map[{mapping.table, mapping.address + offset}]
      )

  defp store(state, mapping, value, raw) do
    keys =
      for offset <- 0..(Codec.size(mapping) - 1), do: {mapping.table, mapping.address + offset}

    %{
      state
      | map: Map.merge(state.map, Map.new(Enum.zip(keys, raw))),
        values: Map.put(state.values, mapping.id, value)
    }
  end

  defp publish_all(state, mappings) do
    Enum.each(mappings, &Endpoint.publish(state.config, &1, state.values[&1.id]))
    state
  end
end
