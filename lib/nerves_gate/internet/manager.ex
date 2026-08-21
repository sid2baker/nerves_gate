defmodule NervesGate.Internet.Manager do
  @moduledoc "Applies candidate uplink settings and persists only verified configurations."

  use GenServer

  alias NervesGate.Backoff
  alias NervesGate.Internet.Config
  alias NervesGate.Internet.Connectivity
  alias NervesGate.Storage.Alarms, as: StorageAlarms
  alias NervesGate.Store

  @initial_retry 250

  defstruct [:adapter, :verifier, :root, :known_good, :pending, checks: %{}]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec apply_candidate(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply_candidate(config, options \\ []) do
    server = Keyword.get(options, :server, __MODULE__)
    timeout = Keyword.get(options, :timeout, 30_000)
    GenServer.call(server, {:apply_candidate, config, timeout}, timeout + 2_000)
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @spec reapply(GenServer.server()) :: :ok | {:error, term()}
  def reapply(server \\ __MODULE__), do: GenServer.call(server, :reapply)

  @impl true
  def init(options) do
    root = Keyword.get(options, :root, Store.root())
    adapter = Keyword.get(options, :adapter, configured_adapter())
    verifier = Keyword.get(options, :verifier, &Connectivity.verify/1)

    {known_good, storage_error?} =
      case Store.read_network(root) do
        {:ok, %Config{} = config} -> {config, false}
        {:ok, nil} -> {nil, false}
        {:error, _reason} -> {nil, true}
      end

    if storage_error?, do: StorageAlarms.failure(true)
    if known_good, do: adapter.configure_uplink(known_good)

    {:ok, %__MODULE__{adapter: adapter, verifier: verifier, root: root, known_good: known_good}}
  end

  @impl true
  def handle_call({:apply_candidate, %Config{} = config, timeout}, from, %{pending: nil} = state) do
    case state.adapter.configure_uplink(config) do
      :ok ->
        pending = %{
          config: config,
          deadline: System.monotonic_time(:millisecond) + timeout,
          delay: @initial_retry,
          from: from
        }

        send(self(), :verify_candidate)
        {:noreply, %{state | pending: pending}}

      {:error, reason} ->
        {:reply, {:error, {:apply_failed, reason}}, state}
    end
  end

  def handle_call({:apply_candidate, %Config{}, _timeout}, _from, state) do
    {:reply, {:error, :candidate_in_progress}, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      checks: state.checks,
      known_good: Config.to_public(state.known_good),
      verifying: not is_nil(state.pending)
    }

    {:reply, status, state}
  end

  def handle_call(:reapply, _from, %{known_good: %Config{} = config} = state) do
    {:reply, state.adapter.configure_uplink(config), state}
  end

  def handle_call(:reapply, _from, state), do: {:reply, {:error, :not_configured}, state}

  @impl true
  def handle_info(:verify_candidate, %{pending: pending} = state) when not is_nil(pending) do
    checks = state.verifier.(pending.config.interface)

    cond do
      Connectivity.internet_ready?(checks) ->
        finish_verified(state, checks)

      System.monotonic_time(:millisecond) >= pending.deadline ->
        finish_failed(state, checks)

      true ->
        {wait, next_delay} = Backoff.next(pending.delay, 4_000)
        Process.send_after(self(), :verify_candidate, wait)
        {:noreply, %{state | pending: %{pending | delay: next_delay}, checks: checks}}
    end
  end

  def handle_info(:verify_candidate, state), do: {:noreply, state}

  defp finish_verified(%{pending: pending} = state, checks) do
    case Store.write_network(pending.config, state.root) do
      :ok ->
        GenServer.reply(pending.from, {:ok, checks})
        broadcast({:network_verified, Config.to_public(pending.config), checks})
        {:noreply, %{state | pending: nil, known_good: pending.config, checks: checks}}

      {:error, reason} ->
        StorageAlarms.failure(true)
        rollback(state)
        GenServer.reply(pending.from, {:error, {:persistence_failed, reason}})
        {:noreply, %{state | pending: nil, checks: checks}}
    end
  end

  defp finish_failed(%{pending: pending} = state, checks) do
    rollback(state)
    GenServer.reply(pending.from, {:error, {:verification_failed, checks}})
    broadcast({:network_rollback, checks})
    {:noreply, %{state | pending: nil, checks: checks}}
  end

  defp rollback(%{known_good: %Config{} = known_good, adapter: adapter}),
    do: adapter.configure_uplink(known_good)

  defp rollback(%{pending: %{config: config}, adapter: adapter}),
    do: adapter.clear(config.interface)

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "internet_configuration", message)

    # Compatibility: remove this compatibility topic during the NervesGateWeb refactor.
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "network", message)
  end

  defp configured_adapter do
    Application.fetch_env!(:nerves_gate, :internet_adapter)
  end
end
