defmodule NervesGate.StartupGate do
  @moduledoc """
  Completes the one-time hardware-watchdog boot handshake after public hydration.

  The gate is supervised outside the restartable Backend subtree. Rebuilding
  DeviceState later in the same VM therefore does not repeat the boot-health
  decision.
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
    enabled =
      Keyword.get(
        options,
        :enabled,
        Application.get_env(:nerves_gate, :startup_gate_enabled, false)
      )

    callback = Keyword.get(options, :callback, &Nerves.Runtime.Heart.init_complete/0)

    if enabled do
      server = Keyword.get(options, :device_state, NervesGate.DeviceState.Server)
      {:ok, snapshot} = DeviceState.subscribe(self(), server)

      state = %{
        completed: false,
        state: snapshot.state,
        boot_id: snapshot.boot_id,
        revision: snapshot.revision,
        callback: callback
      }

      {:ok, maybe_complete(state)}
    else
      {:ok, %{completed: true, state: nil, boot_id: nil, revision: 0, callback: callback}}
    end
  end

  @impl true
  def handle_info(_message, %{completed: true} = state), do: {:noreply, state}

  def handle_info(
        {:device_state_event, _node, boot_id, revision, event},
        %{boot_id: boot_id, revision: previous} = state
      )
      when revision == previous + 1 do
    case State.apply_event(state.state, event) do
      {:ok, public_state} ->
        {:noreply, maybe_complete(%{state | state: public_state, revision: revision})}

      :error ->
        {:stop, :invalid_device_state_event, state}
    end
  end

  def handle_info({:device_state_event, _node, _boot, _revision, _event}, state),
    do: {:stop, :device_state_revision_gap, state}

  defp maybe_complete(%{completed: false, state: %State{} = public_state} = state) do
    if State.hydrated?(public_state) do
      :ok = state.callback.()
      %{state | completed: true}
    else
      state
    end
  end
end
