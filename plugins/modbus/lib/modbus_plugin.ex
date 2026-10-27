defmodule ModbusPlugin do
  @moduledoc "Explicitly configured, read-only Modbus TCP devices using yamodbus. Startup opens no connections."
  use GenServer
  alias ModbusPlugin.{Config, Connection}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def configure(id, params), do: GenServer.call(__MODULE__, {:configure, id, params})
  def connect(id), do: GenServer.call(__MODULE__, {:connect, id})
  def disconnect(id), do: GenServer.call(__MODULE__, {:disconnect, id})
  def status, do: GenServer.call(__MODULE__, :status)
  def health_check, do: if(Process.whereis(__MODULE__), do: :ok, else: {:error, :not_running})

  def init(_), do: {:ok, %{}}

  def handle_call({:configure, id, params}, _, configs) do
    with {:ok, config} <- Config.validate(id, params),
         true <- Map.has_key?(configs, id) or map_size(configs) < 16,
         nil <- Connection.pid(id) do
      {:reply, :ok, Map.put(configs, id, config)}
    else
      false -> {:reply, {:error, :device_limit}, configs}
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

        {config, nil} ->
          case DynamicSupervisor.start_child(ModbusPlugin.Connections, {Connection, config}) do
            {:ok, _} -> :ok
            {:error, _} -> {:error, :connection_start_failed}
          end
      end

    {:reply, result, configs}
  end

  def handle_call({:disconnect, id}, _, configs) do
    result =
      case Connection.pid(id) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(ModbusPlugin.Connections, pid)
      end

    {:reply, result, configs}
  end

  def handle_call(:status, _, configs) do
    devices = for {id, config} <- Enum.sort(configs), do: Map.merge(config, Connection.status(id))
    {:reply, devices, configs}
  end
end
