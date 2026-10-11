defmodule NervesGate.Connectivity.Sensor do
  @moduledoc """
  Jido-owned input runtime. Coalesces property changes, derives Alarmist inputs
  and bridges only condition transitions. Existing subsystem tables remain the
  source; no property mirror or event log is kept. Rechecks are linked, bounded
  workers and cannot overlap. Subscriptions die with this process.
  """
  use GenServer
  alias NervesGate.Connectivity.{Alarms, Signals}
  alias NervesGate.{Network, Observations}

  def start_link(init), do: GenServer.start_link(__MODULE__, init)

  @impl true
  def init(init) do
    Process.flag(:trap_exit, true)
    config = init.plugin_state
    :ok = Alarms.start(config.scope)
    :ok = Alarms.subscribe(config.scope)
    :ok = Network.observe(config.network)
    Process.send_after(self(), :reconcile, 5_000)

    state = %{
      agent: init.agent_server,
      config: config,
      worker: nil,
      revision: nil,
      sample_timer: nil,
      condition_timer: nil
    }

    Jido.AgentServer.cast(
      init.agent_server,
      Signals.new("connectivity.reconcile", %{active: false})
    )

    {:ok, schedule_sample(state)}
  end

  @impl true
  def handle_call({:effect, %{operation: :cancel}}, _, state),
    do: {:reply, :ok, stop_worker(state)}

  def handle_call({:effect, effect}, _, state) do
    # The agent serializes attempts; still enforce ownership at the effect edge.
    state = stop_worker(state)
    config = state.config
    task = Task.async(fn -> config.probe.read(config.network, config.remote) end)
    timer = Process.send_after(self(), {:timeout, task.ref}, config.timeout)
    worker = %{task: task, timer: timer, outage: effect.outage, attempt: effect.attempt}
    {:reply, :ok, %{state | worker: worker}}
  end

  @impl true
  def handle_info(:sample, state) do
    Alarms.update(state.config.scope, internet(state.config.network))
    {:noreply, schedule_condition(%{state | sample_timer: nil})}
  end

  def handle_info(:condition, state) do
    {:noreply, publish_condition(%{state | condition_timer: nil})}
  end

  def handle_info(:reconcile, state) do
    # Rebind after source table/runtime restarts. The normal path is event driven.
    Network.observe(state.config.network)
    Alarms.subscribe(state.config.scope)
    Process.send_after(self(), :reconcile, 5_000)

    Jido.AgentServer.cast(
      state.agent,
      Signals.new("connectivity.reconcile", %{active: state.worker != nil})
    )

    {:noreply, state |> publish_condition(true) |> schedule_sample()}
  end

  def handle_info(%PropertyTable.Event{}, state), do: {:noreply, schedule_sample(state)}
  def handle_info({VintageNet, _, _, _, _}, state), do: {:noreply, schedule_sample(state)}
  def handle_info(%Alarmist.Event{}, state), do: {:noreply, schedule_condition(state)}

  def handle_info({ref, result}, %{worker: %{task: %{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finished(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{worker: %{task: %{ref: ref}}} = state),
    do: {:noreply, finished(state, :unavailable)}

  def handle_info({:timeout, ref}, %{worker: %{task: %{ref: ref}} = worker} = state) do
    Task.shutdown(worker.task, :brutal_kill)
    {:noreply, finished(state, :unavailable)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    stop_worker(state)
    :ok
  end

  defp finished(%{worker: worker} = state, result) do
    Process.cancel_timer(worker.timer)
    data = %{outage: worker.outage, attempt: worker.attempt}
    signal = Signals.new("connectivity.recheck.completed", data, state.config.scope)
    Jido.AgentServer.cast(state.agent, signal)
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "connectivity:events", signal)
    if is_map(result), do: Alarms.update(state.config.scope, result.internet)
    schedule_sample(%{state | worker: nil})
  end

  defp stop_worker(%{worker: nil} = state), do: state

  defp stop_worker(%{worker: worker} = state) do
    Task.shutdown(worker.task, :brutal_kill)
    Process.cancel_timer(worker.timer)
    %{state | worker: nil}
  end

  defp internet(network) do
    network |> Network.status() |> Observations.Network.internet()
  catch
    _, _ -> :unavailable
  end

  defp publish_condition(state, force \\ false) do
    case Alarms.condition(state.config.scope) do
      {condition, revision}
      when condition in [:set, :clear] and (revision != state.revision or force) ->
        type = if condition == :set, do: "connectivity.lost", else: "connectivity.restored"
        signal = Signals.new(type, %{revision: revision}, state.config.scope)
        Jido.AgentServer.cast(state.agent, signal)

        if revision != state.revision,
          do: Phoenix.PubSub.broadcast(NervesGate.PubSub, "connectivity:events", signal)

        %{state | revision: revision}

      _ ->
        state
    end
  end

  defp schedule_sample(%{sample_timer: nil} = state),
    do: %{state | sample_timer: Process.send_after(self(), :sample, 20)}

  defp schedule_sample(state), do: state

  defp schedule_condition(%{condition_timer: nil} = state),
    do: %{state | condition_timer: Process.send_after(self(), :condition, 20)}

  defp schedule_condition(state), do: state
end
