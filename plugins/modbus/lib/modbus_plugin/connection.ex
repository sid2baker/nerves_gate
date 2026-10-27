defmodule ModbusPlugin.Connection do
  @moduledoc "One supervised read-only TCP/RTU connection, with at most one poll in flight."
  use GenServer, restart: :temporary

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
      nil -> %{state: :disconnected, values: nil, error: nil, read_at: nil}
      pid -> GenServer.call(pid, :status, 1_000)
    end
  catch
    :exit, _ -> %{state: :unavailable, values: nil, error: :connection_unavailable, read_at: nil}
  end

  def init(config) do
    # Supervisor shutdown must run terminate/2 and synchronously close the client.
    Process.flag(:trap_exit, true)

    {:ok, client} = Modbus.Client.start_link(client_options(config))

    send(self(), :poll)

    {:ok,
     %{
       config: config,
       client: client,
       pending: nil,
       status: %{state: :polling, values: nil, error: nil, read_at: nil}
     }}
  end

  @doc false
  def client_options(%{transport: "rtu"} = config) do
    [
      rtu: config.serial_path,
      speed: 9600,
      data_bits: 8,
      stop_bits: 1,
      parity: :none,
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

  def handle_info(:poll, %{pending: nil} = state) do
    config = state.config

    function =
      if config.table == :holding, do: :read_holding_registers, else: :read_input_registers

    ref =
      Modbus.Client.send_request(
        state.client,
        config.unit,
        {function, config.address, config.count},
        timeout: config.timeout
      )

    {:noreply, %{state | pending: ref}}
  end

  def handle_info({Modbus.Client, ref, result}, %{pending: ref} = state) when is_reference(ref) do
    status =
      case result do
        {:ok, values} ->
          %{
            state: :polling,
            values: values,
            error: nil,
            read_at: DateTime.to_iso8601(DateTime.utc_now())
          }

        {:error, reason} ->
          %{state: :read_failed, values: nil, error: reason, read_at: state.status.read_at}
      end

    Process.send_after(self(), :poll, state.config.interval)
    {:noreply, %{state | pending: nil, status: status}}
  end

  def handle_info({:EXIT, client, reason}, %{client: client} = state),
    do: {:stop, {:client_exit, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, state) do
    if Process.alive?(state.client), do: Modbus.Client.stop(state.client)
    :ok
  end
end
