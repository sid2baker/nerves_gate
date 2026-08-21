defmodule NervesGate.Cluster.Manager do
  @moduledoc "Starts libcluster after distribution and reports BEAM connection truth."

  use GenServer

  alias NervesGate.Alarm
  alias NervesGate.Alarms

  defstruct [:supervisor, candidates: [], connected: []]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started, do: GenServer.call(__MODULE__, :ensure_started)

  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_options) do
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "tailscale")
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "beam")
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:ensure_started, _from, %{supervisor: pid} = state) when is_pid(pid) do
    {:reply, :ok, state}
  end

  def handle_call(:ensure_started, _from, state) do
    topologies = [nervesgate: [strategy: NervesGate.Cluster.TailscaleStrategy, config: []]]

    child_spec = %{
      id: NervesGate.LibclusterSupervisor,
      start:
        {Cluster.Supervisor, :start_link, [[topologies, [name: NervesGate.LibclusterSupervisor]]]},
      restart: :temporary,
      type: :supervisor
    }

    case DynamicSupervisor.start_child(NervesGate.Cluster.DynamicSupervisor, child_spec) do
      {:ok, pid} -> {:reply, :ok, %{state | supervisor: pid}}
      {:error, {:already_started, pid}} -> {:reply, :ok, %{state | supervisor: pid}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       running: is_pid(state.supervisor) and Process.alive?(state.supervisor),
       candidates: Enum.map(state.candidates, &Atom.to_string/1),
       connected: Enum.map(state.connected, &Atom.to_string/1),
       missing: missing(state) |> Enum.map(&Atom.to_string/1)
     }, state}
  end

  @impl true
  def handle_info({:tailscale_changed, status}, state) do
    state = %{state | candidates: status.candidates}
    report_degraded(state)
    {:noreply, state}
  end

  def handle_info({:nodes_changed, connected}, state) do
    state = %{state | connected: MapSet.to_list(connected)}
    report_degraded(state)
    {:noreply, state}
  end

  def handle_info({:distribution_online, _node_name}, state), do: {:noreply, state}

  defp report_degraded(state) do
    Alarms.toggle(Alarm.DegradedCluster, missing(state) != [])
  end

  defp missing(state), do: state.candidates -- state.connected
end
