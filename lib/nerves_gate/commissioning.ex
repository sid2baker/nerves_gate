defmodule NervesGate.Commissioning do
  @moduledoc """
  Owns temporary local commissioning interfaces.

  Desired access and observed interface configurations are reconciled directly
  by one GenServer. There is no protocol whose legal events depend on a formal
  lifecycle phase, so an FSM would only duplicate the reconciliation logic.
  """

  use GenServer

  alias NervesGate.Commissioning.{Access, Status}
  alias NervesGate.Internet.Hardware
  alias NervesGate.Retry

  @retry_delay 2_000
  @tick_interval 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    state = Keyword.get_lazy(options, :payload, &new/0)
    GenServer.start_link(__MODULE__, state, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    %{
      phase: :disabled,
      desired: %{mode: :disabled, uplink: nil},
      active: [],
      adapter:
        Keyword.get(options, :adapter, Application.fetch_env!(:nerves_gate, :internet_adapter)),
      hardware: Keyword.get(options, :hardware, &Hardware.interfaces/0),
      publisher: Keyword.get(options, :publisher, &publish/1),
      retry_delay: Keyword.get(options, :retry_delay, @retry_delay),
      last_error: nil,
      blocked_by: nil,
      attempt: 0,
      retry_at: nil
    }
  end

  @spec enable(:commissioning, String.t() | nil, GenServer.server()) ::
          {:ok, [map()]} | {:error, :no_interface | term()}
  def enable(:commissioning, uplink \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:enable, uplink}, 20_000)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec disable(GenServer.server()) :: :ok | {:error, term()}
  def disable(server \\ __MODULE__) do
    GenServer.call(server, :disable, 20_000)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec release(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def release(interface, server \\ __MODULE__) do
    GenServer.call(server, {:release, interface})
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec heal(GenServer.server()) :: :ok | {:error, :no_interface | term()}
  def heal(server \\ __MODULE__) do
    GenServer.call(server, :heal, 20_000)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec status(GenServer.server()) :: Status.t()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _reason -> %Status{state: :disabled, active: [], mode: :disabled}
  end

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server \\ __MODULE__) do
    GenServer.call(server, :diagnostics)
  catch
    :exit, _reason -> nil
  end

  @impl true
  def init(state) do
    schedule_tick()
    publish_state(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:enable, uplink}, _from, state) do
    state = %{state | desired: %{mode: :commissioning, uplink: uplink}}
    {reply, state} = reconcile(state, :enable)
    publish_state(state)
    {:reply, reply, state}
  end

  def handle_call(:disable, _from, state) do
    state = %{state | desired: %{mode: :disabled, uplink: nil}}
    {reply, state} = reconcile(state, :disable)
    publish_state(state)
    {:reply, reply, state}
  end

  def handle_call(:heal, _from, %{phase: :disabled} = state), do: {:reply, :ok, state}

  def handle_call(:heal, _from, state) do
    {reply, state} = reconcile(state, :heal)
    publish_state(state)
    {:reply, reply, state}
  end

  def handle_call({:release, interface}, _from, state) do
    active = Enum.reject(state.active, &(&1.interface == interface))
    phase = if active == [], do: :waiting, else: state.phase
    state = %{state | active: active, phase: phase}
    publish_state(state)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}
  def handle_call(:diagnostics, _from, state), do: {:reply, diagnostic_view(state), state}

  @impl true
  def handle_cast({:tick, _payload}, state) do
    {:noreply, periodic_reconcile(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, periodic_reconcile(state)}
  end

  defp periodic_reconcile(%{phase: :disabled} = state), do: state

  defp periodic_reconcile(%{phase: :backoff} = state) do
    if Retry.due?(state.retry_at) do
      {_reply, state} = reconcile(state, :tick)
      publish_state(state)
      state
    else
      state
    end
  end

  defp periodic_reconcile(state) do
    {_reply, state} = reconcile(state, :tick)
    publish_state(state)
    state
  end

  defp reconcile(state, command) do
    result = runtime_reconcile(state)

    case result do
      {:ok, active} ->
        phase = if state.desired.mode == :disabled, do: :disabled, else: :active

        state = %{
          state
          | phase: phase,
            active: active,
            last_error: nil,
            blocked_by: nil,
            attempt: 0,
            retry_at: nil
        }

        {command_result(command, active), state}

      {:error, :no_interface} ->
        state = %{
          state
          | phase: :waiting,
            active: [],
            last_error: nil,
            blocked_by: :hardware
        }

        {{:error, :no_interface}, state}
    end
  catch
    _kind, reason ->
      error = {:commissioning_reconciliation_crashed, Retry.public_error(reason)}
      state = enter_backoff(state, error)
      {{:error, error}, state}
  end

  defp runtime_reconcile(state) do
    interfaces = state.hardware.()

    case state.desired.mode do
      :disabled ->
        Access.clear_all(state.adapter, interfaces, state.active, state.desired.uplink)
        {:ok, []}

      :commissioning ->
        Access.reconcile(state.adapter, interfaces, state.active, state.desired.uplink)
    end
  end

  defp command_result(:enable, active), do: {:ok, active}
  defp command_result(_command, _active), do: :ok

  defp enter_backoff(state, error) do
    %{
      state
      | phase: :backoff,
        last_error: error,
        blocked_by: nil,
        attempt: state.attempt + 1,
        retry_at: Retry.now() + state.retry_delay
    }
  end

  defp public_status(state) do
    %Status{state: state.phase, active: state.active, mode: state.desired.mode}
  end

  defp diagnostic_view(state) do
    %{
      state: state.phase,
      desired: state.desired,
      observed: %{active: state.active},
      blocked_by: state.blocked_by,
      last_error: state.last_error,
      attempt: state.attempt,
      retry_at: state.retry_at
    }
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)
  defp publish_state(state), do: state.publisher.(public_status(state))

  defp publish(status) do
    case NervesGate.DeviceState.publish({:state_reported, :commissioning, status}) do
      :ok -> :ok
      {:error, :shutting_down} -> :ok
      {:error, reason} -> raise "Commissioning DeviceState publication failed: #{inspect(reason)}"
    end
  end
end
