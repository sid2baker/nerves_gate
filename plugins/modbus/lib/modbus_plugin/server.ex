defmodule ModbusPlugin.Server do
  @moduledoc """
  One explicitly started Modbus server exposing exactly the saved mappings.
  The runtime process owns the visible register/coil map: remote masters and
  explicit local changes update it, and every mapping is published as an
  ordinary platform input. Requests outside the mapped points are refused.
  The library runs each request handler in a short-lived process, so handlers
  only forward to this owner and never touch the platform themselves.
  """
  use GenServer, restart: :temporary
  @behaviour Modbus.Server
  alias ModbusPlugin.{Connection, Endpoint}

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
      map = Map.new(config.mappings, &{{&1.table, &1.address}, &1.initial})
      state = %{config: config, server: server, map: map, status: nil}
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
  def handle_call(:status, _, state) do
    values = Map.new(state.config.mappings, &{&1.id, state.map[{&1.table, &1.address}]})
    {:reply, %{state: :serving, values: values, error: nil, read_at: nil}, state}
  end

  def handle_call({:put, mapping_id, value}, _, state) do
    case Enum.find(state.config.mappings, &(&1.id == mapping_id)) do
      %{table: table, address: address} = mapping when table == :holding or table == :coil ->
        if fits?(table, value) do
          map = Map.put(state.map, {table, address}, value)
          {:reply, :ok, publish_all(%{state | map: map}, [mapping])}
        else
          {:reply, {:error, :invalid_value}, state}
        end

      nil ->
        {:reply, {:error, :unknown_mapping}, state}
    end
  end

  def handle_call({:request, unit, _}, _, %{config: %{unit: own}} = state) when unit != own,
    do: {:reply, {:error, {:exception, :gateway_path_unavailable}}, state}

  def handle_call({:request, _, {function, address, count}}, _, state)
      when function in [:read_coils, :read_holding_registers] do
    table = if function == :read_coils, do: :coil, else: :holding
    keys = for offset <- 0..(count - 1), do: {table, address + offset}

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

  defp write(state, table, address, values) do
    keys = for {_, offset} <- Enum.with_index(values), do: {table, address + offset}

    if Enum.all?(keys, &Map.has_key?(state.map, &1)) and Enum.all?(values, &fits?(table, &1)) do
      map = Map.merge(state.map, Map.new(Enum.zip(keys, values)))
      changed = Enum.filter(state.config.mappings, &({&1.table, &1.address} in keys))
      {:reply, :ok, publish_all(%{state | map: map}, changed)}
    else
      {:reply, {:error, {:exception, :illegal_data_address}}, state}
    end
  end

  defp fits?(:coil, value), do: is_boolean(value)
  defp fits?(:holding, value), do: is_integer(value) and value in 0..65535

  defp publish_all(state, mappings) do
    Enum.each(mappings, fn mapping ->
      Endpoint.publish(state.config, mapping, state.map[{mapping.table, mapping.address}])
    end)

    state
  end
end
