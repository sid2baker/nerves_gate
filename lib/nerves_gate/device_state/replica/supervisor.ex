defmodule NervesGate.DeviceState.Replica.Supervisor do
  @moduledoc "Supervises one replica lifecycle FSM per connected remote node."

  use Supervisor

  alias NervesGate.DeviceState.Replica
  alias NervesGate.DeviceState.Replica.Scanner

  @registry NervesGate.DeviceState.Replica.Registry
  @dynamic NervesGate.DeviceState.Replica.DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec sync_connected() :: :ok
  def sync_connected do
    Node.list(:connected)
    |> Enum.reject(&(&1 == Node.self()))
    |> Enum.each(&ensure/1)

    :ok
  end

  @spec replicas() :: %{String.t() => map()}
  def replicas do
    entries()
    |> Enum.map(fn {_node, pid} -> Replica.replica(pid) end)
    |> Enum.reject(&is_nil/1)
    |> Map.new(fn replica -> {replica.state.device.device_id, replica} end)
  end

  @spec diagnostics() :: %{node() => map()}
  def diagnostics do
    Map.new(entries(), fn {node, pid} -> {node, Replica.diagnostics(pid)} end)
  end

  @impl true
  def init(_options) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @dynamic},
      Scanner
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp ensure(remote_node) do
    case Registry.lookup(@registry, remote_node) do
      [{_pid, _value}] ->
        :ok

      [] ->
        name = {:via, Registry, {@registry, remote_node}}

        child = %{
          id: {Replica, remote_node},
          start: {Replica, :start_link, [[payload: Replica.new(remote_node), name: name]]},
          restart: :transient
        }

        case DynamicSupervisor.start_child(@dynamic, child) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
    end
  end

  defp entries do
    if Process.whereis(@registry) do
      Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    else
      []
    end
  end
end
