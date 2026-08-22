defmodule NervesGate.Internet.Manager do
  @moduledoc "Owns verified Internet configuration, guarded candidates, and rollback."

  use GenServer

  alias NervesGate.Backoff
  alias NervesGate.Internet.Config
  alias NervesGate.Internet.Connectivity
  alias NervesGate.Settings.ChangeControl
  alias NervesGate.Storage.Alarms, as: StorageAlarms
  alias NervesGate.Store

  @initial_retry 250
  @default_confirmation_timeout :timer.minutes(5)

  defstruct [
    :adapter,
    :verifier,
    :root,
    :known_good,
    :pending,
    :staged,
    :confirmation_timer,
    :change_control,
    checks: %{},
    confirmation_timeout: @default_confirmation_timeout
  ]

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

  @doc "Applies a verified candidate temporarily and starts its confirmation deadline."
  @spec stage_candidate(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stage_candidate(config, connection_id, options \\ []) when is_binary(connection_id) do
    server = Keyword.get(options, :server, __MODULE__)
    timeout = Keyword.get(options, :timeout, 30_000)
    GenServer.call(server, {:stage_candidate, config, connection_id, timeout}, timeout + 2_000)
  end

  @spec confirm(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def confirm(change_id, connection_id, server \\ __MODULE__) do
    GenServer.call(server, {:confirm, change_id, connection_id})
  end

  @spec revert(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def revert(change_id, server \\ __MODULE__), do: GenServer.call(server, {:revert, change_id})

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

    state = %__MODULE__{
      adapter: adapter,
      verifier: verifier,
      root: root,
      known_good: known_good,
      change_control: Keyword.get(options, :change_control, ChangeControl),
      confirmation_timeout:
        Keyword.get(
          options,
          :confirmation_timeout,
          Application.get_env(
            :nerves_gate,
            :settings_confirmation_timeout,
            @default_confirmation_timeout
          )
        )
    }

    if change_active?(state), do: send(self(), :recover_unconfirmed_change)
    {:ok, state}
  end

  @impl true
  def handle_call({:apply_candidate, %Config{} = config, timeout}, from, state) do
    begin_candidate(state, config, timeout, from, :commit, nil)
  end

  def handle_call(
        {:stage_candidate, %Config{} = config, connection_id, timeout},
        from,
        %{pending: nil, staged: nil} = state
      ) do
    id = change_id()

    case state.change_control.begin_change(:internet, id, self(), connection_id, %{}) do
      :ok -> begin_candidate(state, config, timeout, from, :stage, {id, connection_id})
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stage_candidate, %Config{}, _connection_id, _timeout}, _from, state) do
    {:reply, {:error, :candidate_in_progress}, state}
  end

  def handle_call({:confirm, id, connection_id}, _from, %{staged: %{id: id}} = state) do
    if state.staged.source_connection == connection_id do
      {:reply, {:error, :fresh_connection_required}, state}
    else
      case Store.write_network(state.staged.config, state.root) do
        :ok ->
          broadcast(
            {:network_committed, Config.to_public(state.staged.config), state.staged.checks}
          )

          :ok = state.change_control.finish(id)
          cancel_confirmation_timer(state)

          {:reply, :ok,
           %{
             state
             | staged: nil,
               confirmation_timer: nil,
               known_good: state.staged.config,
               checks: state.staged.checks
           }}

        {:error, reason} ->
          StorageAlarms.failure(true)
          state = rollback_staged_state(state, {:persistence_failed, reason})
          {:reply, {:error, {:persistence_failed, reason}}, state}
      end
    end
  end

  def handle_call({:confirm, _id, _connection_id}, _from, state) do
    {:reply, {:error, :settings_change_not_found}, state}
  end

  def handle_call({:revert, id}, _from, %{staged: %{id: id}} = state) do
    {:reply, :ok, rollback_staged_state(state, :reverted)}
  end

  def handle_call({:revert, _id}, _from, state) do
    {:reply, {:error, :settings_change_not_found}, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      checks: state.checks,
      known_good: Config.to_public(state.known_good),
      verifying: not is_nil(state.pending),
      pending: public_pending(state)
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

  def handle_info({:confirmation_timeout, id}, %{staged: %{id: id}} = state) do
    {:noreply, rollback_staged_state(state, :confirmation_timeout)}
  end

  def handle_info({:confirmation_timeout, _id}, state), do: {:noreply, state}

  def handle_info(:recover_unconfirmed_change, state) do
    case state.change_control.active(:internet) do
      %{id: id} ->
        rollback_to_known_good(state)
        :ok = state.change_control.finish(id, :recovered_unconfirmed_change)
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  defp begin_candidate(state, config, timeout, from, mode, change) do
    case state.adapter.configure_uplink(config) do
      :ok ->
        pending = %{
          config: config,
          deadline: System.monotonic_time(:millisecond) + timeout,
          delay: @initial_retry,
          from: from,
          mode: mode,
          change: change
        }

        send(self(), :verify_candidate)
        {:noreply, %{state | pending: pending}}

      {:error, reason} ->
        if match?({_, _}, change) do
          {id, _connection_id} = change
          :ok = state.change_control.finish(id, {:apply_failed, reason})
        end

        {:reply, {:error, {:apply_failed, reason}}, state}
    end
  end

  defp finish_verified(%{pending: %{mode: :stage} = pending} = state, checks) do
    {id, source_connection} = pending.change

    case state.change_control.awaiting_confirmation(id, %{}, state.confirmation_timeout) do
      :ok ->
        timer =
          Process.send_after(self(), {:confirmation_timeout, id}, state.confirmation_timeout)

        staged = %{
          id: id,
          source_connection: source_connection,
          config: pending.config,
          checks: checks,
          confirmation_deadline: System.monotonic_time(:millisecond) + state.confirmation_timeout
        }

        GenServer.reply(pending.from, {:ok, public_staged(staged)})
        broadcast({:network_staged, Config.to_public(pending.config), checks})

        {:noreply,
         %{state | pending: nil, staged: staged, confirmation_timer: timer, checks: checks}}

      {:error, reason} ->
        rollback(state)
        GenServer.reply(pending.from, {:error, reason})
        :ok = state.change_control.finish(id, reason)
        {:noreply, %{state | pending: nil, checks: checks}}
    end
  end

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

    if pending.mode == :stage do
      {id, _source_connection} = pending.change
      :ok = state.change_control.finish(id, :verification_failed)
    end

    {:noreply, %{state | pending: nil, checks: checks}}
  end

  defp rollback_staged_state(state, reason) do
    id = state.staged.id
    cancel_confirmation_timer(state)
    rollback_to_known_good(state)
    broadcast({:network_rollback, state.checks})
    :ok = state.change_control.finish(id, reason)
    %{state | staged: nil, confirmation_timer: nil}
  end

  defp rollback_to_known_good(%{known_good: %Config{} = known_good, adapter: adapter}),
    do: adapter.configure_uplink(known_good)

  defp rollback_to_known_good(%{staged: %{config: config}, adapter: adapter}),
    do: adapter.clear(config.interface)

  defp rollback_to_known_good(_state), do: :ok

  defp rollback(%{known_good: %Config{} = known_good, adapter: adapter}),
    do: adapter.configure_uplink(known_good)

  defp rollback(%{pending: %{config: config}, adapter: adapter}),
    do: adapter.clear(config.interface)

  defp cancel_confirmation_timer(%{confirmation_timer: nil}), do: :ok
  defp cancel_confirmation_timer(state), do: Process.cancel_timer(state.confirmation_timer)

  defp public_pending(%{pending: %{mode: :stage} = pending}) do
    {id, _source_connection} = pending.change
    %{id: id, phase: :applying, remaining_seconds: nil}
  end

  defp public_pending(%{staged: staged}) when not is_nil(staged), do: public_staged(staged)
  defp public_pending(_state), do: nil

  defp public_staged(staged) do
    %{
      id: staged.id,
      phase: :awaiting_confirmation,
      remaining_seconds:
        max(
          0,
          div(staged.confirmation_deadline - System.monotonic_time(:millisecond) + 999, 1_000)
        )
    }
  end

  defp change_active?(state), do: not is_nil(state.change_control.active(:internet))

  defp change_id do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp broadcast(message) do
    Phoenix.PubSub.local_broadcast(NervesGate.PubSub, "internet_configuration", message)
  end

  defp configured_adapter do
    Application.fetch_env!(:nerves_gate, :internet_adapter)
  end
end
