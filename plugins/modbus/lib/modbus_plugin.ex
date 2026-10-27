defmodule ModbusPlugin do
  @moduledoc "Explicitly configured, read-only Modbus TCP/RTU devices using yamodbus. Startup opens no connections."
  use GenServer
  alias ModbusPlugin.{Config, Connection}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def configure(id, params), do: GenServer.call(__MODULE__, {:configure, id, params})
  def connect(id), do: GenServer.call(__MODULE__, {:connect, id})
  def disconnect(id), do: GenServer.call(__MODULE__, {:disconnect, id})
  def status, do: GenServer.call(__MODULE__, :status)
  def ports, do: GenServer.call(__MODULE__, :ports)
  def health_check, do: if(Process.whereis(__MODULE__), do: :ok, else: {:error, :not_running})

  def init(_), do: {:ok, %{}}

  def handle_call(:ports, _, configs), do: {:reply, NervesGateSDK.Hardware.resources(), configs}

  def handle_call({:configure, id, params}, _, configs) do
    with {:ok, config} <- Config.validate(id, params),
         true <- Map.has_key?(configs, id) or map_size(configs) < 16,
         false <- Map.has_key?(Map.get(configs, id, %{}), :serial_monitor),
         nil <- Connection.pid(id) do
      {:reply, :ok, Map.put(configs, id, config)}
    else
      false -> {:reply, {:error, :device_limit}, configs}
      true -> {:reply, {:error, :connection_cleanup_required}, configs}
      pid when is_pid(pid) -> {:reply, {:error, :disconnect_first}, configs}
      error -> {:reply, error, configs}
    end
  end

  def handle_call({:connect, id}, _, configs) do
    result =
      case {configs[id], Connection.pid(id)} do
        {nil, _} ->
          {:error, :configure_first}

        {_, pid} when is_pid(pid) ->
          {:error, :already_started}

        {%{serial_monitor: _}, nil} ->
          {:error, :connection_cleanup_required}

        {config, nil} ->
          with :ok <- serial_exclusive(config, configs),
               {:ok, config} <- assigned_transport(config) do
            case DynamicSupervisor.start_child(ModbusPlugin.Connections, {Connection, config}) do
              {:ok, pid} -> {:ok, pid}
              {:error, _} -> {:error, :connection_start_failed}
            end
          end
      end

    case result do
      {:ok, pid} ->
        configs =
          if configs[id].transport == "rtu",
            do: put_in(configs[id][:serial_monitor], Process.monitor(pid)),
            else: configs

        {:reply, :ok, configs}

      error ->
        {:reply, error, configs}
    end
  end

  def handle_call({:disconnect, id}, _, configs) do
    result =
      case Connection.pid(id) do
        nil ->
          if get_in(configs, [id, :serial_monitor]),
            do: {:error, :connection_cleanup_required},
            else: :ok

        pid ->
          DynamicSupervisor.terminate_child(ModbusPlugin.Connections, pid)
      end

    configs =
      if result == :ok and get_in(configs, [id, :serial_monitor]) do
        Process.demonitor(configs[id].serial_monitor, [:flush])
        Map.update!(configs, id, &Map.delete(&1, :serial_monitor))
      else
        configs
      end

    {:reply, result, configs}
  end

  def handle_call(:status, _, configs) do
    devices =
      for {id, config} <- Enum.sort(configs) do
        status =
          if config[:serial_monitor] && Connection.pid(id) == nil,
            do: %{
              state: :cleanup_required,
              values: nil,
              error: :restart_plugin_to_verify_cleanup,
              read_at: nil
            },
            else: Connection.status(id)

        Map.merge(Map.delete(config, :serial_monitor), status)
      end

    {:reply, devices, configs}
  end

  # Retain the serial marker after unexpected death: a missing worker is not
  # proof its native handle drained. Only checked disconnect or plugin stop clears it.
  def handle_info({:DOWN, _, :process, _, _}, configs), do: {:noreply, configs}

  defp serial_exclusive(%{transport: "rtu", serial_port: port}, configs) do
    busy =
      Enum.any?(configs, fn {id, config} ->
        config.transport == "rtu" and config.serial_port == port and
          (Connection.pid(id) != nil or Map.has_key?(config, :serial_monitor))
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
