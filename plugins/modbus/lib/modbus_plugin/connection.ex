defmodule ModbusPlugin.Connection do
  @moduledoc """
  One explicitly started Modbus client. The runtime process registers its
  mapped inputs/outputs with the platform before opening the transport, then
  serializes one request at a time: pending desires are written first, then
  inputs are read. Desire is read right before each setter, so stale queued
  writes never happen; a lost writer (nil desire) causes no physical write.
  Any read failure publishes the input as invalid (exception) or unknown.
  """
  use GenServer, restart: :temporary
  alias ModbusPlugin.Endpoint
  alias NervesGateSDK.IO, as: SDKIO

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

  def init(config) do
    # Supervisor shutdown must run terminate/2 and synchronously close the client.
    Process.flag(:trap_exit, true)

    with :ok <- Endpoint.register(config, self()),
         {:ok, client} <- start_client(config) do
      send(self(), :poll)

      {:ok,
       %{
         config: config,
         client: client,
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

  defp start_client(config) do
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

  def handle_info(:poll, %{pending: nil, queue: []} = state) do
    {outputs, inputs} = Enum.split_with(state.config.mappings, &(&1.direction == :output))
    queue = Enum.map(outputs, &{:write, &1}) ++ Enum.map(inputs, &{:read, &1})
    {:noreply, next(%{state | queue: queue, timer: nil})}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info(
        {:nerves_gate_output_changed, _},
        %{pending: nil, queue: [], timer: timer} = state
      )
      when timer != nil do
    Process.cancel_timer(timer)
    send(self(), :poll)
    {:noreply, %{state | timer: nil}}
  end

  def handle_info({Modbus.Client, ref, result}, %{pending: {ref, operation}} = state) do
    {:noreply, state |> complete(operation, result) |> Map.put(:pending, nil) |> next()}
  end

  def handle_info({:EXIT, client, reason}, %{client: client} = state),
    do: {:stop, {:client_exit, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, state) do
    if Process.alive?(state.client), do: Modbus.Client.stop(state.client)
    :ok
  end

  defp next(%{queue: []} = state) do
    timer = Process.send_after(self(), :poll, state.config.interval)
    %{state | timer: timer}
  end

  defp next(%{queue: [{:read, mapping} | queue]} = state) do
    function = if mapping.table == :coil, do: :read_coils, else: :read_holding_registers
    request(%{state | queue: queue}, {:read, mapping}, {function, mapping.address, 1})
  end

  defp next(%{queue: [{:write, mapping} | queue]} = state) do
    state = %{state | queue: queue}

    case SDKIO.read_desired(Endpoint.id(state.config, mapping)) do
      {:ok, nil} ->
        next(%{state | written: Map.delete(state.written, mapping.id)})

      {:ok, value} ->
        if state.written[mapping.id] == value and feedback_matches?(state, mapping, value) do
          next(state)
        else
          function =
            if mapping.table == :coil, do: :write_single_coil, else: :write_single_register

          request(state, {:write, mapping, value}, {function, mapping.address, value})
        end

      {:error, reason} ->
        next(put_in(state.status.error, {:desired_unavailable, reason}))
    end
  end

  # Repeatable setter reconciliation: rewrite when linked feedback disagrees.
  defp feedback_matches?(_, %{feedback: nil}, _), do: true

  defp feedback_matches?(state, %{feedback: feedback}, value),
    do: Map.get(state.status.values, feedback) == value

  defp request(state, operation, request) do
    ref =
      Modbus.Client.send_request(state.client, state.config.unit, request,
        timeout: state.config.timeout
      )

    %{state | pending: {ref, operation}}
  end

  defp complete(state, {:read, mapping}, {:ok, [value]}) do
    Endpoint.publish(state.config, mapping, value)

    put_in(state.status, %{
      state: :polling,
      values: Map.put(state.status.values, mapping.id, value),
      error: nil,
      read_at: DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp complete(state, {:read, mapping}, result) do
    reason = failure(result)
    quality = if match?({:exception, _}, reason), do: :invalid, else: :unknown
    Endpoint.publish(state.config, mapping, nil, quality)
    failed(state, Map.delete(state.status.values, mapping.id), reason)
  end

  defp complete(state, {:write, mapping, value}, :ok),
    do: %{state | written: Map.put(state.written, mapping.id, value)}

  defp complete(state, {:write, mapping, _}, result) do
    state = %{state | written: Map.delete(state.written, mapping.id)}
    failed(state, state.status.values, {:write_failed, mapping.id, failure(result)})
  end

  defp failed(state, values, reason),
    do: put_in(state.status, %{state.status | state: :failed, values: values, error: reason})

  defp failure({:error, reason}), do: reason
  defp failure(other), do: {:unexpected_response, other}
end
