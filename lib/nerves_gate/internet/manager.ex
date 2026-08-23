defmodule NervesGate.Internet.Manager do
  @moduledoc "Applies and verifies the Internet configuration selected by DeviceState.Server."

  use GenServer

  alias NervesGate.Backoff
  alias NervesGate.Internet.Config
  alias NervesGate.Internet.Connectivity

  @initial_retry 250

  defstruct [:adapter, :verifier, :current, :pending, checks: %{}]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec configure(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def configure(config, options \\ []) do
    server = Keyword.get(options, :server, __MODULE__)
    timeout = Keyword.get(options, :timeout, 30_000)
    GenServer.call(server, {:configure, config, timeout}, timeout + 2_000)
  end

  @spec restore(Config.t() | nil, GenServer.server()) :: :ok | {:error, term()}
  def restore(config, server \\ __MODULE__), do: GenServer.call(server, {:restore, config})

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @spec reapply(GenServer.server()) :: :ok | {:error, term()}
  def reapply(server \\ __MODULE__), do: GenServer.call(server, :reapply)

  @impl true
  def init(options) do
    {:ok,
     %__MODULE__{
       adapter: Keyword.get(options, :adapter, configured_adapter()),
       verifier: Keyword.get(options, :verifier, &Connectivity.verify/1)
     }}
  end

  @impl true
  def handle_call({:configure, %Config{} = config, timeout}, from, %{pending: nil} = state) do
    case state.adapter.configure_uplink(config) do
      :ok ->
        pending = %{
          config: config,
          previous: state.current,
          deadline: System.monotonic_time(:millisecond) + timeout,
          delay: @initial_retry,
          from: from
        }

        send(self(), :verify)
        {:noreply, %{state | pending: pending}}

      {:error, reason} ->
        {:reply, {:error, {:apply_failed, reason}}, state}
    end
  end

  def handle_call({:configure, %Config{}, _timeout}, _from, state) do
    {:reply, {:error, :configuration_in_progress}, state}
  end

  def handle_call({:restore, config}, _from, state) do
    case restore_config(state, config) do
      :ok ->
        broadcast({:network_restored, Config.to_public(config)})
        {:reply, :ok, %{state | current: config, pending: nil}}

      {:error, reason} ->
        {:reply, {:error, {:restore_failed, reason}}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       checks: state.checks,
       known_good: Config.to_public(state.current),
       verifying: not is_nil(state.pending),
       pending: if(state.pending, do: %{phase: :applying})
     }, state}
  end

  def handle_call(:reapply, _from, %{current: %Config{} = config} = state) do
    {:reply, state.adapter.configure_uplink(config), state}
  end

  def handle_call(:reapply, _from, state), do: {:reply, {:error, :not_configured}, state}

  @impl true
  def handle_info(:verify, %{pending: pending} = state) when not is_nil(pending) do
    checks = state.verifier.(pending.config.interface)

    cond do
      Connectivity.internet_ready?(checks) ->
        GenServer.reply(pending.from, {:ok, checks})
        broadcast({:network_verified, Config.to_public(pending.config), checks})
        {:noreply, %{state | pending: nil, current: pending.config, checks: checks}}

      System.monotonic_time(:millisecond) >= pending.deadline ->
        restore_pending(state, pending)
        GenServer.reply(pending.from, {:error, {:verification_failed, checks}})
        broadcast({:network_rollback, checks})
        {:noreply, %{state | pending: nil, current: pending.previous, checks: checks}}

      true ->
        {wait, next_delay} = Backoff.next(pending.delay, 4_000)
        Process.send_after(self(), :verify, wait)
        pending = %{pending | delay: next_delay}
        {:noreply, %{state | pending: pending, checks: checks}}
    end
  end

  def handle_info(:verify, state), do: {:noreply, state}

  defp restore_pending(state, %{config: config, previous: previous}) do
    if previous && previous.interface == config.interface do
      state.adapter.configure_uplink(previous)
    else
      with :ok <- state.adapter.clear(config.interface) do
        restore_config(state, previous)
      end
    end
  end

  defp restore_config(
         %{current: %Config{interface: current_interface}} = state,
         %Config{interface: interface} = config
       )
       when current_interface != interface do
    with :ok <- state.adapter.clear(current_interface) do
      state.adapter.configure_uplink(config)
    end
  end

  defp restore_config(state, %Config{} = config), do: state.adapter.configure_uplink(config)

  defp restore_config(%{current: %Config{interface: interface}} = state, nil) do
    state.adapter.clear(interface)
  end

  defp restore_config(_state, nil), do: :ok

  defp broadcast(message) do
    Phoenix.PubSub.local_broadcast(NervesGate.PubSub, "internet_configuration", message)
  end

  defp configured_adapter do
    Application.fetch_env!(:nerves_gate, :internet_adapter)
  end
end
