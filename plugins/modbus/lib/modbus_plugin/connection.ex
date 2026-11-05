defmodule ModbusPlugin.Connection do
  @moduledoc "One raw client: each range is one coherent read; explicit writes serialize with polling and are never retried."
  use GenServer, restart: :temporary
  alias ModbusPlugin.Protocol

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
      nil -> %{state: :stopped, observations: %{}, error: nil}
      pid -> GenServer.call(pid, :status, 1000)
    end
  catch
    :exit, _ -> %{state: :unavailable, observations: %{}, error: :connection_unavailable}
  end

  @doc "Write a whole explicitly writable range once. An unknown outcome must not be blindly retried."
  def write(id, range_id, values) do
    case pid(id) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:write, range_id, values}, 11_000)
    end
  catch
    :exit, _ -> {:error, :outcome_unknown}
  end

  def init(config) do
    Process.flag(:trap_exit, true)

    with {:ok, client} <- start_client(config) do
      send(self(), :poll)

      {:ok,
       %{config: config, client: client, queue: [], pending: nil, timer: nil, observations: %{}}}
    else
      {:error, reason} -> {:stop, reason}
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
  def client_options(%{transport: "rtu"} = config),
    do: [
      rtu: config.serial_path,
      speed: config.speed,
      data_bits: 8,
      stop_bits: config.stop_bits,
      parity: config.parity,
      timeout: config.timeout
    ]

  def client_options(config),
    do: [
      tcp: config.host,
      port: config.port,
      timeout: config.timeout,
      connect_timeout: config.timeout,
      max_pending: 1
    ]

  def handle_call(:status, _, state) do
    error = Enum.find_value(state.observations, fn {_, observation} -> observation.error end)

    {:reply,
     %{
       state: if(error, do: :failed, else: :polling),
       observations: state.observations,
       error: error
     }, state}
  end

  def handle_call({:put, _, _}, _, state), do: {:reply, {:error, :server_required}, state}

  def handle_call({:write, range_id, values}, from, state) do
    range = Enum.find(state.config.ranges, &(&1.id == range_id))

    busy =
      match?({_, {:write, _, _}}, state.pending) or
        Enum.any?(state.queue, &match?({{:write, _, _}, _}, &1))

    cond do
      range == nil ->
        {:reply, {:error, :unknown_range}, state}

      not range.writable ->
        {:reply, {:error, :read_only}, state}

      not Protocol.valid_values?(range, values) ->
        {:reply, {:error, :invalid_raw_values}, state}

      busy ->
        {:reply, {:error, :busy}, state}

      true ->
        operation = {:write, from, range}
        state = %{state | queue: [{operation, Protocol.write(range, values)} | state.queue]}

        if state.pending do
          {:noreply, state}
        else
          if state.timer, do: Process.cancel_timer(state.timer)
          {:noreply, next(%{state | timer: nil})}
        end
    end
  end

  def handle_info(:poll, %{pending: nil, queue: []} = state) do
    queue = for range <- state.config.ranges, do: {{:read, range}, Protocol.read(range)}
    {:noreply, next(%{state | queue: queue, timer: nil})}
  end

  def handle_info({Modbus.Client, ref, result}, %{pending: {ref, operation}} = state),
    do: {:noreply, state |> complete(operation, result) |> Map.put(:pending, nil) |> next()}

  def handle_info({:EXIT, client, reason}, %{client: client} = state),
    do: {:stop, {:client_exit, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, state) do
    if Process.alive?(state.client), do: Modbus.Client.stop(state.client)
    :ok
  end

  defp next(%{queue: []} = state),
    do: %{state | timer: Process.send_after(self(), :poll, state.config.interval)}

  defp next(%{queue: [{operation, request} | queue]} = state) do
    ref =
      Modbus.Client.send_request(state.client, state.config.unit, request,
        timeout: state.config.timeout
      )

    %{state | pending: {ref, operation}, queue: queue}
  end

  defp complete(state, {:read, range}, {:ok, values} = result) do
    if Protocol.valid_values?(range, values),
      do: observe(state, range, values, :good, nil),
      else: complete(state, {:read, range}, {:error, {:unexpected_response, result}})
  end

  defp complete(state, {:read, range}, {:error, reason}),
    do:
      observe(
        state,
        range,
        nil,
        if(match?({:exception, _}, reason), do: :invalid, else: :unknown),
        reason
      )

  defp complete(state, {:read, range}, result),
    do: complete(state, {:read, range}, {:error, {:unexpected_response, result}})

  defp complete(state, {:write, from, range}, result) do
    reply =
      case result do
        :ok -> :ok
        {:error, {:exception, _} = reason} -> {:error, reason}
        _ -> {:error, :outcome_unknown}
      end

    GenServer.reply(from, reply)
    observe(state, range, nil, :unknown, if(reply == :ok, do: nil, else: elem(reply, 1)))
  end

  defp observe(state, range, values, quality, error) do
    observation = %{
      values: values,
      quality: quality,
      error: error,
      observed_at: DateTime.to_iso8601(DateTime.utc_now())
    }

    put_in(state.observations[range.id], observation)
  end
end
