defmodule NervesGate.Boot.Gate do
  @moduledoc """
  Completes the hardware-watchdog handshake once public state is hydrated.

  The temporary gate lives outside the restartable Backend subtree and exits
  after completion, so the boot-health decision cannot repeat in the same VM.
  """

  use GenServer

  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.Client

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

      {:ok, client} = Client.install(snapshot)

      state = %{
        client: client,
        device_state_server: server,
        callback: Keyword.get(options, :callback, &Nerves.Runtime.Heart.init_complete/0)
      }

      if client.hydrated do
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
  def handle_info({:device_state_operation, _, _, _, _} = operation, state) do
    state.client
    |> Client.reduce(operation)
    |> reduce_result(state)
  end

  def handle_info({:device_state_heartbeat, _, _, _}, state), do: {:noreply, state}

  defp reduce_result({:ok, client, :changed}, state),
    do: continue_or_complete(%{state | client: client})

  defp reduce_result({:ok, _client, :duplicate}, state), do: {:noreply, state}
  defp reduce_result(:resync, state), do: resynchronize(state)

  defp resynchronize(state) do
    {:ok, snapshot} = DeviceState.subscribe(self(), state.device_state_server)
    {:ok, client} = Client.install(snapshot)
    continue_or_complete(%{state | client: client})
  end

  defp continue_or_complete(%{client: %{hydrated: true}} = state), do: complete(state)
  defp continue_or_complete(state), do: {:noreply, state}

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
