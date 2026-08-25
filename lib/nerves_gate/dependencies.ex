defmodule NervesGate.Dependencies do
  @moduledoc """
  Restartable projection bridge from canonical public state to private lifecycle inputs.

  It owns no desired state, retries, effects, persistence, or healing. Its only
  state is a local DeviceState projection and revision used to reconstruct and
  dispatch current dependency evidence.
  """

  use GenServer

  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.State

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl true
  def init(options) do
    server = Keyword.get(options, :device_state, NervesGate.DeviceState.Server)
    dispatch = Keyword.get(options, :dispatch, &dispatch/2)
    {:ok, snapshot} = DeviceState.subscribe(self(), server)

    state = %{
      device_state: snapshot.state,
      boot_id: snapshot.boot_id,
      revision: snapshot.revision,
      device_state_server: server,
      dispatch: dispatch
    }

    project_snapshot(state)
    {:ok, state}
  end

  @impl true
  def handle_info(
        {:device_state_event, _node, boot_id, revision, event},
        %{boot_id: boot_id, revision: previous} = state
      )
      when revision == previous + 1 do
    case State.apply_event(state.device_state, event) do
      {:ok, device_state} ->
        state = %{state | device_state: device_state, revision: revision}
        project_event(state, event)
        {:noreply, state}

      :error ->
        {:stop, :invalid_device_state_event, state}
    end
  end

  def handle_info(
        {:device_state_event, _node, boot_id, revision, _event},
        %{boot_id: boot_id, revision: current} = state
      )
      when revision <= current,
      do: {:noreply, state}

  def handle_info({:device_state_event, _node, _boot_id, _revision, _event}, state) do
    # There is deliberately no replay buffer. Reinstall one atomic current
    # snapshot, then continue with events after that snapshot's revision.
    {:ok, snapshot} = DeviceState.subscribe(self(), state.device_state_server)

    state = %{
      state
      | device_state: snapshot.state,
        boot_id: snapshot.boot_id,
        revision: snapshot.revision
    }

    project_snapshot(state)
    {:noreply, state}
  end

  defp project_snapshot(state) do
    case state.device_state.tailnet do
      nil -> :ok
      status -> state.dispatch.(:tailnet, status)
    end
  end

  defp project_event(state, {:state_reported, :tailnet, status}),
    do: state.dispatch.(:tailnet, status)

  # Alarm state is output from policy and never evidence for signal derivation.
  defp project_event(_state, {:state_reported, :alarms, _alarms}), do: :ok
  defp project_event(_state, _event), do: :ok

  defp dispatch(:tailnet, status) do
    if GenServer.whereis(NervesGate.SSH), do: NervesGate.SSH.tailnet_state_changed(status)

    if GenServer.whereis(NervesGate.SubnetRouter),
      do: NervesGate.SubnetRouter.tailnet_state_changed(status)

    transition_if_running(NervesGate.Cluster, :tick)
  end

  defp transition_if_running(name, event) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) -> GenServer.cast(pid, {event, nil})
      nil -> :ok
    end
  end
end
