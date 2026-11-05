defmodule ModbusPlugin.Connection do
  @moduledoc """
  One explicitly started Modbus client. The runtime process registers its mapped
  inputs with the platform and opens the transport, then starts a linked
  `NervesGateSDK.Output` runtime for its outputs. It serializes one request at a
  time: setters requested by that runtime go first, then the poll's batched
  reads (`ModbusPlugin.Plan`). The runtime always applies the newest Desire, so
  stale queued writes never happen; a released Desire causes no physical write.
  When readback disagrees with the last written value, the output is applied
  again. A failed batch publishes each of its inputs as invalid (exception) or
  unknown; a value that does not decode is invalid.
  """
  use GenServer, restart: :temporary
  alias ModbusPlugin.{Codec, Endpoint, Outputs, Plan}

  def start_link(config),
    do:
      GenServer.start_link(__MODULE__, config,
        name: {:via, Registry, {ModbusPlugin.Registry, config.id}}
      )

  def pid(id) do
    case Registry.lookup(ModbusPlugin.Registry, id) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  def status(id) do
    case pid(id) do
      nil -> %{state: :stopped, values: nil, error: nil, read_at: nil}
      pid -> GenServer.call(pid, :status, 1_000)
    end
  catch
    :exit, _ -> %{state: :unavailable, values: nil, error: :connection_unavailable, read_at: nil}
  end

  @doc false
  def write(connection, mapping_id, value, timeout) do
    GenServer.call(connection, {:write, mapping_id, value}, timeout * 2 + 1_000)
  catch
    :exit, _ -> {:error, :timeout}
  end

  @doc false
  def forget(connection, mapping_id), do: GenServer.cast(connection, {:forget, mapping_id})

  def init(config) do
    # Supervisor shutdown must run terminate/2 and synchronously close the client.
    Process.flag(:trap_exit, true)

    with :ok <- Endpoint.register(config),
         {:ok, client} <- start_client(config),
         {:ok, outputs} <- start_outputs(config) do
      send(self(), :poll)

      {:ok,
       %{
         config: config,
         plan: Plan.build(config),
         client: client,
         outputs: outputs,
         pending: nil,
         queue: [],
         timer: nil,
         written: %{},
         status: %{state: :polling, values: %{}, error: nil, read_at: nil}
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_outputs(config) do
    state = %{
      connection: self(),
      prefix: config.id <> ".",
      timeout: config.timeout,
      interval: config.interval
    }

    case NervesGateSDK.Output.start_link(Outputs, Endpoint.outputs(config), state) do
      {:ok, outputs} -> {:ok, outputs}
      {:error, reason} -> {:error, {:outputs_start_failed, reason}}
    end
  end

  @doc false
  def start_client(config) do
    case Modbus.Client.start_link(client_options(config)) do
      {:ok, client} -> {:ok, client}
      {:error, reason} -> {:error, {:client_start_failed, reason}}
    end
  end

  @doc false
  def client_options(%{transport: "rtu"} = config) do
    [
      rtu: config.serial_path,
      speed: config.speed,
      data_bits: 8,
      stop_bits: config.stop_bits,
      parity: config.parity,
      timeout: config.timeout
    ]
  end

  def client_options(config) do
    [
      tcp: config.host,
      port: config.port,
      timeout: config.timeout,
      connect_timeout: config.timeout,
      max_pending: 1
    ]
  end

  def handle_call(:status, _, state), do: {:reply, state.status, state}

  def handle_call({:write, mapping_id, value}, from, state) do
    with %{} = mapping <-
           Enum.find(state.config.mappings, &(&1.id == mapping_id and &1.access == :write)),
         {:ok, words} <- Codec.encode(mapping, value) do
      state = %{state | queue: [{:write, from, mapping, value, words} | state.queue]}
      if state.pending == nil, do: {:noreply, cancel_and_next(state)}, else: {:noreply, state}
    else
      nil -> {:reply, {:error, :unknown_output}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_cast({:forget, mapping_id}, state),
    do: {:noreply, %{state | written: Map.delete(state.written, mapping_id)}}

  def handle_info(:poll, %{pending: nil, queue: []} = state),
    do: {:noreply, next(%{state | queue: Enum.map(state.plan, &{:read, &1}), timer: nil})}

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({Modbus.Client, ref, result}, %{pending: {ref, operation}} = state) do
    {:noreply, state |> complete(operation, result) |> Map.put(:pending, nil) |> next()}
  end

  def handle_info({:EXIT, client, reason}, %{client: client} = state),
    do: {:stop, {:client_exit, reason}, state}

  def handle_info({:EXIT, outputs, reason}, %{outputs: outputs} = state),
    do: {:stop, {:outputs_exit, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, state) do
    if Process.alive?(state.client), do: Modbus.Client.stop(state.client)
    :ok
  end

  # A setter requested while idle runs now, not after the poll interval.
  defp cancel_and_next(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    next(%{state | timer: nil})
  end

  defp next(%{queue: []} = state) do
    timer = Process.send_after(self(), :poll, state.config.interval)
    %{state | timer: timer}
  end

  defp next(%{queue: [{:read, batch} | queue]} = state),
    do: request(%{state | queue: queue}, {:read, batch}, Plan.request(batch))

  defp next(%{queue: [{:write, from, mapping, value, words} | queue]} = state),
    do: request(%{state | queue: queue}, {:write, from, mapping, value}, write(mapping, words))

  defp write(%{table: :coil, address: address}, [bit]), do: {:write_single_coil, address, bit}

  defp write(%{address: address}, [word]), do: {:write_single_register, address, word}
  defp write(%{address: address}, words), do: {:write_multiple_registers, address, words}

  # Repeatable setter reconciliation: rewrite when readback disagrees with the
  # last written value. The Output runtime re-reads the current Desire first.
  defp reconcile_feedback(state, input, value) do
    for %{access: :write, feedback: feedback, id: id} = mapping <- state.config.mappings,
        feedback == input.id,
        Map.has_key?(state.written, id),
        state.written[id] != value do
      NervesGateSDK.Output.reapply(state.outputs, Endpoint.id(state.config, mapping))
    end

    state
  end

  defp request(state, operation, request) do
    ref =
      Modbus.Client.send_request(state.client, state.config.unit, request,
        timeout: state.config.timeout
      )

    %{state | pending: {ref, operation}}
  end

  defp complete(state, {:read, batch}, {:ok, values}) when length(values) == batch.count do
    {state, errors} =
      Enum.reduce(Plan.decode(batch, values), {state, []}, fn
        {mapping, {:ok, value}}, {state, errors} ->
          Endpoint.publish(state.config, mapping, value)
          state = put_in(state.status.values[mapping.id], value)
          {reconcile_feedback(state, mapping, value), errors}

        {mapping, {:error, reason}}, {state, errors} ->
          Endpoint.publish(state.config, mapping, nil, :invalid)

          {update_in(state.status.values, &Map.delete(&1, mapping.id)),
           [{mapping.id, reason} | errors]}
      end)

    state = put_in(state.status.read_at, DateTime.to_iso8601(DateTime.utc_now()))

    case errors do
      [] -> put_in(state.status, %{state.status | state: :polling, error: nil})
      errors -> failed(state, state.status.values, {:decode_failed, Enum.reverse(errors)})
    end
  end

  defp complete(state, {:read, batch}, result) do
    reason = failure(result)
    quality = if match?({:exception, _}, reason), do: :invalid, else: :unknown
    Enum.each(batch.mappings, &Endpoint.publish(state.config, &1, nil, quality))
    values = Map.drop(state.status.values, Enum.map(batch.mappings, & &1.id))
    failed(state, values, {:read_failed, batch.table, batch.address, batch.count, reason})
  end

  defp complete(state, {:write, from, mapping, value}, :ok) do
    GenServer.reply(from, :ok)
    %{state | written: Map.put(state.written, mapping.id, value)}
  end

  defp complete(state, {:write, from, mapping, _}, result) do
    GenServer.reply(from, {:error, failure(result)})
    state = %{state | written: Map.delete(state.written, mapping.id)}
    failed(state, state.status.values, {:write_failed, mapping.id, failure(result)})
  end

  defp failed(state, values, reason),
    do: put_in(state.status, %{state.status | state: :failed, values: values, error: reason})

  defp failure({:error, reason}), do: reason
  defp failure(other), do: {:unexpected_response, other}
end
