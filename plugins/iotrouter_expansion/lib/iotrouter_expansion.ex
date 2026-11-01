defmodule IotrouterExpansion do
  @moduledoc """
  IOTRouter expansion cards (EM300 expansion bus) as platform inputs and outputs.

  Nothing is opened at startup. `start/0` explicitly resets the card chain on this
  plugin's enabled `:iotrouter_expansion` assignment, discovers the cards and starts
  cyclic exchange; `stop/0` closes the bus. Card endpoints are registered from what
  is discovered, so there is no saved configuration.
  """
  use GenServer
  alias IotrouterExpansion.Bus

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def start, do: GenServer.call(__MODULE__, :start, 10_000)
  def stop, do: GenServer.call(__MODULE__, :stop, 10_000)
  def status, do: GenServer.call(__MODULE__, :status)
  def ports, do: GenServer.call(__MODULE__, :ports)
  def health_check, do: if(Process.whereis(__MODULE__), do: :ok, else: {:error, :not_running})

  @impl true
  def init(_), do: {:ok, %{error: nil, monitor: nil}}

  @impl true
  def handle_call(:start, _, %{error: {:bus_stopped, _}} = state),
    do: {:reply, {:error, :restart_plugin_to_verify_cleanup}, state}

  def handle_call(:start, _, %{monitor: nil} = state) do
    case assigned() do
      {:ok, port} ->
        case DynamicSupervisor.start_child(IotrouterExpansion.Buses, {Bus, port}) do
          {:ok, pid} ->
            {:reply, :ok, %{state | error: nil, monitor: Process.monitor(pid)}}

          {:error, reason} ->
            # Starting may already have reset/configured cards. Do not assume a
            # failed child start proves all native handles drained.
            {:reply, {:error, reason}, %{state | error: {:bus_stopped, reason}}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | error: reason}}
    end
  end

  def handle_call(:start, _, state), do: {:reply, {:error, :already_started}, state}

  def handle_call(:stop, _, state) do
    case GenServer.whereis(Bus) do
      nil ->
        if state.error && match?({:bus_stopped, _}, state.error) do
          {:reply, {:error, :restart_plugin_to_verify_cleanup}, state}
        else
          {:reply, :ok, state}
        end

      pid ->
        case DynamicSupervisor.terminate_child(IotrouterExpansion.Buses, pid) do
          :ok ->
            if state.monitor, do: Process.demonitor(state.monitor, [:flush])
            {:reply, :ok, %{state | monitor: nil, error: nil}}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call(:status, _, state),
    do: {:reply, Map.put(Bus.status(), :error, state.error), state}

  def handle_call(:ports, _, state), do: {:reply, NervesGateSDK.Hardware.candidates(), state}

  @impl true
  def handle_info({:DOWN, ref, :process, _, reason}, %{monitor: ref} = state),
    do: {:noreply, %{state | monitor: nil, error: {:bus_stopped, reason}}}

  def handle_info(_, state), do: {:noreply, state}

  defp assigned do
    with {:ok, resources} <- NervesGateSDK.Hardware.resources() do
      case Enum.filter(resources, &(&1.kind == :iotrouter_expansion)) do
        [%{present?: true, path: path} = port] when is_binary(path) -> {:ok, port}
        [] -> {:error, :not_assigned}
        [_] -> {:error, :not_present}
        _ -> {:error, :assign_exactly_one_bus}
      end
    end
  end
end
