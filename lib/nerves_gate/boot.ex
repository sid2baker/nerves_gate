defmodule NervesGate.Boot.Gate do
  @moduledoc """
  Completes the hardware-watchdog handshake once public state is hydrated.

  The temporary gate lives outside the restartable Backend subtree and exits
  after completion, so the boot-health decision cannot repeat in the same VM.
  """

  use GenServer

  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.State

  @doc false
  def child_spec(options) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}, restart: :temporary}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl true
  def init(options) do
    if Keyword.get(
         options,
         :enabled,
         Application.get_env(:nerves_gate, :startup_gate_enabled, false)
       ) do
      server = Keyword.get(options, :device_state, NervesGate.DeviceState.Server)
      {:ok, snapshot} = DeviceState.subscribe(self(), server)

      state = %{
        state: snapshot.state,
        boot_id: snapshot.boot_id,
        revision: snapshot.revision,
        callback: Keyword.get(options, :callback, &Nerves.Runtime.Heart.init_complete/0)
      }

      if State.hydrated?(state.state) do
        :ok = state.callback.()
        :ignore
      else
        {:ok, state}
      end
    else
      :ignore
    end
  end

  @impl true
  def handle_info(
        {:device_state_event, _node, boot_id, revision, event},
        %{boot_id: boot_id, revision: previous} = state
      )
      when revision == previous + 1 do
    case State.apply_event(state.state, event) do
      {:ok, public_state} ->
        state = %{state | state: public_state, revision: revision}
        if State.hydrated?(public_state), do: complete(state), else: {:noreply, state}

      :error ->
        {:stop, :invalid_device_state_event, state}
    end
  end

  def handle_info({:device_state_event, _node, _boot, _revision, _event}, state),
    do: {:stop, :device_state_revision_gap, state}

  defp complete(state) do
    :ok = state.callback.()
    {:stop, :normal, state}
  end
end

defmodule NervesGate.Boot.Shoehorn do
  @moduledoc """
  Retries `:nerves_runtime` once when it fails during Shoehorn boot.

  A successful retry resumes the release at `:nerves_gate`. A second or
  deterministic failure remains visible to the watchdog and firmware fallback.
  """

  @behaviour Shoehorn.Handler

  require Logger

  @impl Shoehorn.Handler
  def init(options) do
    {:ok,
     %{
       retried?: false,
       restart: Keyword.get(options, :restart_application, &Application.ensure_all_started/1)
     }}
  end

  @impl Shoehorn.Handler
  def application_started(_application, state), do: {:continue, state}

  @impl Shoehorn.Handler
  def application_exited(:nerves_runtime, reason, %{retried?: false} = state) do
    Logger.error(
      "Essential application nerves_runtime exited during boot: #{inspect(reason)}; retrying (1/1)"
    )

    Process.sleep(250)
    state = %{state | retried?: true}

    case state.restart.(:nerves_runtime) do
      {:ok, _applications} ->
        Logger.info("Essential application nerves_runtime recovered after a bounded boot retry")
        resume_release(state.restart)

      {:error, retry_reason} ->
        Logger.error(
          "Essential application nerves_runtime boot retry failed: #{inspect(retry_reason)}"
        )
    end

    {:continue, state}
  end

  def application_exited(_application, _reason, state), do: {:continue, state}

  defp resume_release(restart) do
    case restart.(:nerves_gate) do
      {:ok, _applications} ->
        Logger.info("Resumed the release boot sequence at nerves_gate")

      {:error, reason} ->
        Logger.error(
          "Failed to resume the release boot sequence at nerves_gate: #{inspect(reason)}"
        )
    end
  end
end
