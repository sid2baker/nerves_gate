defmodule ModbusPlugin do
  @moduledoc """
  Explicitly started Modbus TCP/RTU clients and servers using yamodbus, with
  mapped registers/coils exposed as platform inputs and outputs.

  Definitions are this plugin version's `NervesGateSDK.Storage` configuration
  term, restored at startup; startup never opens a transport. Save and Start are separate: a running
  connection must be stopped before it is saved again, and Start resolves
  assigned serial ports at that moment. An unexpectedly dead RTU worker keeps
  its port reserved until the whole plugin is restarted, because a missing
  worker is no proof its native handle drained.
  """
  use GenServer
  alias ModbusPlugin.{Connection, Server, Store}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def save(id, params), do: GenServer.call(__MODULE__, {:save, id, params})
  def delete(id), do: GenServer.call(__MODULE__, {:delete, id})
  def start(id), do: GenServer.call(__MODULE__, {:start, id})
  def stop(id), do: GenServer.call(__MODULE__, {:stop, id})
  def status, do: GenServer.call(__MODULE__, :status)
  def ports, do: GenServer.call(__MODULE__, :ports)
  def health_check, do: if(Process.whereis(__MODULE__), do: :ok, else: {:error, :not_running})

  @impl true
  def init(_) do
    case Store.restore() do
      {:ok, configs} -> {:ok, %{configs: configs, error: nil, monitors: %{}}}
      {:error, reason} -> {:ok, %{configs: %{}, error: reason, monitors: %{}}}
    end
  end

  @impl true
  def handle_call(:ports, _, state), do: {:reply, NervesGateSDK.Hardware.resources(), state}

  def handle_call({:save, id, params}, _, state) do
    with :ok <- writable(state, id),
         {:ok, configs} <- Store.put(state.configs, id, params) do
      persist(state, configs)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:delete, id}, _, state) do
    with :ok <- writable(state, id),
         true <- Map.has_key?(state.configs, id) || {:error, :unknown_connection} do
      persist(state, Map.delete(state.configs, id))
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:start, id}, _, state) do
    result =
      case {state.configs[id], Connection.pid(id), state.monitors[id]} do
        {nil, _, _} ->
          {:error, :save_first}

        {_, pid, _} when is_pid(pid) ->
          {:error, :already_started}

        {_, nil, monitor} when monitor != nil ->
          {:error, :connection_cleanup_required}

        {config, nil, nil} ->
          with :ok <- serial_exclusive(config, state),
               {:ok, config} <- assigned_transport(config) do
            start_runtime(config)
          end
      end

    case result do
      {:ok, pid} ->
        monitors =
          if state.configs[id].transport == "rtu",
            do: Map.put(state.monitors, id, Process.monitor(pid)),
            else: state.monitors

        {:reply, :ok, %{state | monitors: monitors}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:stop, id}, _, state) do
    result =
      case Connection.pid(id) do
        nil ->
          if state.monitors[id], do: {:error, :connection_cleanup_required}, else: :ok

        pid ->
          DynamicSupervisor.terminate_child(ModbusPlugin.Connections, pid)
      end

    monitors =
      if result == :ok and state.monitors[id] do
        Process.demonitor(state.monitors[id], [:flush])
        Map.delete(state.monitors, id)
      else
        state.monitors
      end

    {:reply, result, %{state | monitors: monitors}}
  end

  def handle_call(:status, _, state) do
    connections =
      for {id, config} <- Enum.sort(state.configs) do
        status =
          if state.monitors[id] && Connection.pid(id) == nil,
            do: %{
              state: :cleanup_required,
              values: nil,
              error: :restart_plugin_to_verify_cleanup,
              read_at: nil
            },
            else: Connection.status(id)

        Map.merge(config, status)
      end

    {:reply, %{storage: state.error, connections: connections}, state}
  end

  # Retain the serial marker after unexpected death: a missing worker is not
  # proof its native handle drained. Only checked stop or plugin restart clears it.
  @impl true
  def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}

  # A failed or uncertain earlier save or restore blocks saving until the plugin
  # is restarted and reloads what storage actually holds.
  defp writable(%{error: error}, _) when error != nil, do: {:error, error}
  defp writable(state, id), do: idle(state, id)

  defp persist(state, configs) do
    case Store.persist(configs) do
      :ok -> {:reply, :ok, %{state | configs: configs}}
      {:error, :commit_unknown} = error -> {:reply, error, %{state | error: :commit_unknown}}
      error -> {:reply, error, state}
    end
  end

  defp idle(state, id) do
    cond do
      state.monitors[id] != nil -> {:error, :connection_cleanup_required}
      Connection.pid(id) != nil -> {:error, :stop_first}
      true -> :ok
    end
  end

  defp start_runtime(config) do
    module = if config.role == :server, do: Server, else: Connection

    case DynamicSupervisor.start_child(ModbusPlugin.Connections, {module, config}) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  defp serial_exclusive(%{transport: "rtu", serial_port: port}, state) do
    busy =
      Enum.any?(state.configs, fn {id, config} ->
        config.transport == "rtu" and config.serial_port == port and
          (Connection.pid(id) != nil or Map.has_key?(state.monitors, id))
      end)

    if busy, do: {:error, :serial_port_in_use}, else: :ok
  end

  defp serial_exclusive(_, _), do: :ok

  defp assigned_transport(%{transport: "tcp"} = config), do: {:ok, config}

  defp assigned_transport(config) do
    with {:ok, resources} <- NervesGateSDK.Hardware.resources(),
         %{present?: true, path: path} when is_binary(path) <-
           Enum.find(resources, &(&1.id == config.serial_port and &1.kind == :serial)) do
      {:ok, Map.put(config, :serial_path, path)}
    else
      {:error, _} = error -> error
      _ -> {:error, :serial_port_unavailable}
    end
  end
end
