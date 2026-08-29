defmodule NervesGate.Internet do
  @moduledoc """
  Owns and reconciles the gateway's single Internet uplink.

  This is an ordinary GenServer: commands update desired state, one bounded
  owner-bound effect mutates or observes the interface, and completions update
  observed state. New commands coalesce behind an active effect. No lifecycle
  framework is needed because every command is meaningful in every phase.
  """

  use GenServer

  alias NervesGate.FSM.Effect
  alias NervesGate.Internet.{Config, Connectivity, Status}
  alias NervesGate.Reconciliation

  @initial_retry 250
  @check_order [:physical_link, :ip_address, :default_route, :dns, :internet_https]
  @history_limit 20

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: Keyword.get(options, :name, __MODULE__),
      start: {__MODULE__, :start_link, [options]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    state = Keyword.get_lazy(options, :payload, fn -> new(options) end)
    GenServer.start_link(__MODULE__, state, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    current = load_current(options)
    phase = if current, do: :offline, else: :unconfigured

    %{
      phase: phase,
      desired: Config.to_public(current),
      observed: offline(phase, if(current, do: :starting, else: :not_configured)),
      adapter: Keyword.get(options, :adapter, configured_adapter()),
      verifier: Keyword.get(options, :verifier, &Connectivity.verify/1),
      current: current,
      pending: nil,
      checks: %{},
      publisher: Keyword.get(options, :publisher, &publish/1),
      effect_timeout: Keyword.get(options, :effect_timeout, 45_000),
      poll_interval:
        Keyword.get(
          options,
          :poll_interval,
          Application.get_env(:nerves_gate, :internet_poll_interval, 10_000)
        ),
      generation: 0,
      effect: nil,
      last_error: nil,
      blocked_by: nil,
      attempt: 0,
      retry_at: nil,
      history: [phase]
    }
  end

  @spec configure(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def configure(%Config{} = config, options \\ []) do
    server = Keyword.get(options, :server, __MODULE__)
    timeout = Keyword.get(options, :timeout, 30_000)
    GenServer.call(server, {:configure, config, timeout}, timeout + 5_000)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec restore(Config.t() | nil, GenServer.server()) :: :ok | {:error, term()}
  def restore(config, server \\ __MODULE__) do
    GenServer.call(server, {:restore, config}, 35_000)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec heal(GenServer.server()) :: :ok | {:error, term()}
  def heal(server \\ __MODULE__) do
    GenServer.call(server, :heal, 35_000)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec poll_now(GenServer.server()) :: :ok | {:error, term()}
  def poll_now(server \\ __MODULE__) do
    GenServer.call(server, :observe, 10_000)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec status(GenServer.server()) :: Status.t()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _reason -> offline(:unconfigured, :starting)
  end

  @spec configuration_status(GenServer.server()) :: map()
  def configuration_status(server \\ __MODULE__) do
    GenServer.call(server, :configuration_status)
  catch
    :exit, _reason -> %{checks: %{}, known_good: nil, verifying: false, pending: nil}
  end

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server \\ __MODULE__) do
    GenServer.call(server, :diagnostics)
  catch
    :exit, _reason -> nil
  end

  @impl true
  def init(state) do
    schedule_tick(state)
    publish_state(state)
    if state.current, do: send(self(), :restore_current), else: send(self(), :observe_current)
    {:ok, state}
  end

  @impl true
  def handle_call({:configure, config, timeout}, from, state) do
    pending = pending(:configure, config, timeout, from, state)
    {:noreply, state |> set_pending(pending) |> maybe_start_configuration()}
  end

  def handle_call({:restore, config}, from, state) do
    pending = pending(:restore, config, 0, from, state)
    {:noreply, state |> set_pending(pending) |> maybe_start_configuration()}
  end

  def handle_call(:heal, _from, %{phase: :unconfigured} = state),
    do: {:reply, {:error, :not_configured}, state}

  def handle_call(:heal, _from, %{observed: %{reason: :no_carrier}} = state),
    do: {:reply, {:error, :physical_link_down}, state}

  def handle_call(:heal, from, state) do
    pending = pending(:heal, state.current, 30_000, from, state)
    {:noreply, state |> set_pending(pending) |> maybe_start_configuration()}
  end

  def handle_call(:observe, _from, %{effect: %{kind: :configuration}} = state),
    do: {:reply, {:error, :configuration_in_progress}, state}

  def handle_call(:observe, from, state) do
    case start_observation(state, from) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call(:configuration_status, _from, state) do
    status = %{
      checks: state.checks,
      known_good: Config.to_public(state.current),
      verifying: state.phase == :applying,
      pending: if(state.pending, do: %{phase: state.phase})
    }

    {:reply, status, state}
  end

  def handle_call(:diagnostics, _from, state), do: {:reply, diagnostic_view(state), state}
  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(
        {:configuration_completed, {ref, outcome}},
        %{effect: %{ref: ref} = effect} = state
      ) do
    state = %{state | effect: nil}
    {:noreply, state |> complete_configuration(effect, outcome) |> publish_state()}
  end

  def handle_cast(
        {:observation_completed, {ref, outcome}},
        %{effect: %{ref: ref} = effect} = state
      ) do
    state = %{state | effect: nil}
    {:noreply, state |> complete_observation(effect, outcome) |> publish_state()}
  end

  def handle_cast({_event, _stale}, state), do: {:noreply, state}

  @impl true
  def handle_info(:restore_current, %{effect: nil, pending: nil} = state) do
    pending = pending(:restore, state.current, 0, nil, state)
    {:noreply, state |> set_pending(pending) |> maybe_start_configuration()}
  end

  def handle_info(:restore_current, state), do: {:noreply, state}

  def handle_info(:observe_current, state),
    do: {:noreply, start_background_observation(state)}

  def handle_info(:tick, state) do
    schedule_tick(state)

    state =
      cond do
        state.effect ->
          state

        state.phase == :backoff and state.current and Reconciliation.due?(state.retry_at) ->
          pending = pending(:heal, state.current, 30_000, nil, state)
          state |> set_pending(pending) |> maybe_start_configuration()

        state.phase == :backoff and not Reconciliation.due?(state.retry_at) ->
          state

        true ->
          start_background_observation(state)
      end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec summarize(String.t() | nil, map()) :: Status.t()
  def summarize(nil, _checks), do: offline(:unconfigured, :not_configured)

  def summarize(interface, checks) do
    online = Connectivity.internet_ready?(checks)
    reason = if online, do: nil, else: first_failure(checks)

    %Status{
      state: if(online, do: :online, else: :offline),
      interface: interface,
      online: online,
      ready: online,
      reason: reason,
      checks: public_checks(checks)
    }
  end

  defp pending(mode, config, timeout, from, state) do
    %{
      mode: mode,
      config: config,
      previous: previous_for(state),
      deadline: now() + timeout,
      delay: @initial_retry,
      from: from
    }
  end

  defp set_pending(state, pending) do
    if state.pending && state.pending.from,
      do: GenServer.reply(state.pending.from, {:error, :superseded})

    previous = if state.pending, do: state.pending.previous, else: pending.previous
    pending = %{pending | previous: previous}

    %{
      state
      | pending: pending,
        desired: Config.to_public(pending.config),
        generation: state.generation + 1
    }
  end

  defp previous_for(%{pending: %{previous: previous}}), do: previous
  defp previous_for(state), do: state.current

  defp maybe_start_configuration(%{effect: nil, pending: pending} = state)
       when not is_nil(pending),
       do: start_configuration(state)

  defp maybe_start_configuration(state), do: state

  defp start_configuration(state) do
    ref = make_ref()

    effect = %{
      kind: :configuration,
      ref: ref,
      generation: state.generation,
      pending: state.pending
    }

    snapshot = state

    case Effect.start(
           self(),
           ref,
           fn -> transact(snapshot, effect.generation, effect.pending) end,
           fn ref, outcome -> {:configuration_completed, {ref, outcome}} end,
           timeout: state.effect_timeout
         ) do
      {:ok, _coordinator} ->
        state
        |> Map.put(:effect, effect)
        |> transition(:applying)
        |> publish_state()

      {:error, reason} ->
        fail_launch(state, public_error(reason))
    end
  end

  defp start_observation(%{effect: nil} = state, from) do
    ref = make_ref()
    effect = %{kind: :observation, ref: ref, generation: state.generation, from: from}
    snapshot = state

    case Effect.start(
           self(),
           ref,
           fn -> observe_runtime(snapshot, effect.generation) end,
           fn ref, outcome -> {:observation_completed, {ref, outcome}} end,
           timeout: state.effect_timeout
         ) do
      {:ok, _coordinator} -> {:ok, %{state | effect: effect}}
      {:error, reason} -> {:error, public_error(reason), state}
    end
  end

  defp start_observation(state, _from), do: {:error, :configuration_in_progress, state}

  defp start_background_observation(state) do
    case start_observation(state, nil) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  defp transact(state, generation, pending) do
    result =
      case apply_config(state.adapter, state.current, pending.config) do
        :ok when pending.mode == :restore ->
          {:applied, pending, verify_once(state.verifier, pending.config)}

        :ok ->
          case verify_until(state.verifier, pending) do
            {:ok, checks} -> {:applied, pending, checks}
            {:error, checks} -> rollback_result(state.adapter, pending, checks)
          end

        {:error, reason} ->
          rollback_result(state.adapter, pending, %{}, {:apply_failed, public_error(reason)})
      end

    {generation, result}
  end

  defp observe_runtime(state, generation) do
    {generation, state.current, verify_once(state.verifier, state.current)}
  end

  defp complete_configuration(state, effect, {:returned, {generation, terminal}}) do
    state = apply_terminal_reality(state, terminal)

    if generation == state.generation do
      resolve_terminal(state, terminal)
    else
      reply(effect.pending.from, {:error, :superseded})
      maybe_start_configuration(state)
    end
  end

  defp complete_configuration(state, effect, outcome) do
    error = effect_error(:configuration, outcome)

    if effect.generation == state.generation do
      state
      |> Map.put(:pending, nil)
      |> reply_and_return(effect.pending.from, {:error, error})
      |> enter_backoff(error)
    else
      reply(effect.pending.from, {:error, :superseded})
      maybe_start_configuration(state)
    end
  end

  defp complete_observation(state, effect, {:returned, {generation, current, checks}}) do
    if generation == state.generation do
      observed = observation(current, checks)

      state
      |> Map.merge(%{checks: checks, observed: observed, last_error: nil})
      |> transition(state_for_observation(current, observed))
      |> reply_and_return(effect.from, :ok)
    else
      state |> reply_and_return(effect.from, :ok) |> maybe_start_configuration()
    end
  end

  defp complete_observation(state, effect, outcome) do
    error = effect_error(:observation, outcome)
    observed = %{state.observed | state: :offline, reason: public_error(error)}

    state
    |> Map.merge(%{observed: observed, last_error: error})
    |> transition(:offline)
    |> reply_and_return(effect.from, {:error, error})
  end

  defp resolve_terminal(state, {:applied, pending, checks}) do
    observed = observation(pending.config, checks)
    result = if pending.mode == :configure, do: {:ok, checks}, else: :ok

    state
    |> Map.merge(%{
      current: pending.config,
      pending: nil,
      checks: checks,
      observed: observed,
      last_error: nil,
      blocked_by: nil,
      attempt: 0,
      retry_at: nil
    })
    |> transition(state_for_observation(pending.config, observed))
    |> reply_and_return(pending.from, result)
  end

  defp resolve_terminal(state, {:rolled_back, pending, checks, error}) do
    observed = observation(pending.previous, verify_once(state.verifier, pending.previous))

    state
    |> Map.merge(%{
      current: pending.previous,
      pending: nil,
      checks: checks,
      observed: observed,
      last_error: error
    })
    |> transition(state_for_observation(pending.previous, observed))
    |> reply_and_return(pending.from, command_error(pending, checks, error))
  end

  defp resolve_terminal(state, {:rollback_failed, pending, error}) do
    state
    |> Map.put(:pending, nil)
    |> reply_and_return(pending.from, {:error, error})
    |> enter_backoff(error)
  end

  defp apply_terminal_reality(state, {:applied, pending, checks}) do
    %{
      state
      | current: pending.config,
        checks: checks,
        observed: observation(pending.config, checks)
    }
  end

  defp apply_terminal_reality(state, {:rolled_back, pending, _checks, _error}),
    do: %{state | current: pending.previous}

  defp apply_terminal_reality(state, {:rollback_failed, _pending, _error}), do: state

  defp rollback_result(adapter, pending, checks, error \\ nil) do
    error = error || {:verification_failed, public_checks(checks)}

    case restore_previous(adapter, pending) do
      :ok -> {:rolled_back, pending, checks, error}
      {:error, reason} -> {:rollback_failed, pending, {:rollback_failed, public_error(reason)}}
    end
  end

  defp enter_backoff(state, error) do
    attempt = state.attempt + 1

    state
    |> Map.merge(%{
      last_error: error,
      blocked_by: nil,
      attempt: attempt,
      retry_at: now() + min(1_000 * attempt, 30_000)
    })
    |> transition(:backoff)
  end

  defp fail_launch(state, error) do
    pending = state.pending

    state
    |> Map.put(:pending, nil)
    |> reply_and_return(pending && pending.from, {:error, error})
    |> enter_backoff({:effect_launch_failed, error})
  end

  defp verify_until(verifier, pending) do
    checks = verifier.(pending.config.interface)

    cond do
      Connectivity.internet_ready?(checks) ->
        {:ok, checks}

      now() >= pending.deadline ->
        {:error, checks}

      true ->
        {wait, next_delay} = Reconciliation.next_delay(pending.delay, 4_000)
        Process.sleep(min(wait, max(pending.deadline - now(), 0)))
        verify_until(verifier, %{pending | delay: next_delay})
    end
  end

  defp verify_once(_verifier, nil), do: %{}
  defp verify_once(verifier, %Config{interface: interface}), do: verifier.(interface)

  defp apply_config(adapter, current, nil) do
    case current do
      %Config{interface: interface} -> adapter.clear(interface)
      nil -> :ok
    end
  end

  defp apply_config(adapter, current, %Config{} = config) do
    case current do
      %Config{interface: current_interface} when current_interface != config.interface ->
        with :ok <- adapter.clear(current_interface), do: adapter.configure_uplink(config)

      _same_or_empty ->
        adapter.configure_uplink(config)
    end
  end

  defp restore_previous(adapter, %{config: config, previous: previous}) do
    if previous && config && previous.interface == config.interface do
      adapter.configure_uplink(previous)
    else
      with :ok <- maybe_clear(adapter, config), do: apply_previous(adapter, previous)
    end
  end

  defp maybe_clear(_adapter, nil), do: :ok
  defp maybe_clear(adapter, config), do: adapter.clear(config.interface)
  defp apply_previous(_adapter, nil), do: :ok
  defp apply_previous(adapter, previous), do: adapter.configure_uplink(previous)

  defp observation(nil, _checks), do: offline(:unconfigured, :not_configured)
  defp observation(%Config{interface: interface}, checks), do: summarize(interface, checks)

  defp state_for_observation(nil, _observed), do: :unconfigured
  defp state_for_observation(_current, %{online: true}), do: :online
  defp state_for_observation(_current, _observed), do: :offline

  defp transition(state, phase) do
    history = [phase | state.history] |> Enum.uniq() |> Enum.take(@history_limit)
    %{state | phase: phase, history: history}
  end

  defp diagnostic_view(state) do
    %{
      state: state.phase,
      desired: state.desired,
      observed: state.observed,
      blocked_by: state.blocked_by,
      last_error: state.last_error,
      attempt: state.attempt,
      retry_at: state.retry_at,
      history: state.history
    }
  end

  defp reply_and_return(state, from, result) do
    reply(from, result)
    state
  end

  defp reply(nil, _result), do: :ok
  defp reply(from, result), do: GenServer.reply(from, result)

  defp command_error(%{mode: :configure}, checks, _error),
    do: {:error, {:verification_failed, checks}}

  defp command_error(%{mode: :heal}, _checks, _error),
    do: {:error, :connectivity_unavailable}

  defp command_error(%{mode: :restore}, _checks, error), do: {:error, error}

  defp effect_error(:configuration, :timed_out), do: :configuration_timed_out
  defp effect_error(:configuration, :cancelled), do: :configuration_cancelled
  defp effect_error(:observation, :timed_out), do: :observation_timed_out
  defp effect_error(:observation, :cancelled), do: :observation_cancelled

  defp effect_error(:configuration, {:crashed, _kind, reason, _stack}),
    do: {:configuration_crashed, public_error(reason)}

  defp effect_error(:observation, {:crashed, _kind, reason, _stack}),
    do: {:observation_crashed, public_error(reason)}

  defp effect_error(:configuration, _invalid), do: :invalid_configuration_result
  defp effect_error(:observation, _invalid), do: :invalid_observation_result

  defp first_failure(checks) do
    Enum.find_value(@check_order, :unknown, fn check ->
      case Map.get(checks, check) do
        :ok -> nil
        {:error, reason} -> normalize_reason(check, reason)
        _other -> check
      end
    end)
  end

  defp normalize_reason(:physical_link, reason), do: reason
  defp normalize_reason(:ip_address, reason), do: reason
  defp normalize_reason(:default_route, reason), do: reason
  defp normalize_reason(:dns, _reason), do: :dns_failure
  defp normalize_reason(:internet_https, _reason), do: :https_failure

  defp public_checks(checks),
    do: Map.new(checks, fn {key, value} -> {key, public_check(value)} end)

  defp public_check(:ok), do: :ok
  defp public_check({:error, reason}) when is_atom(reason), do: reason
  defp public_check(_value), do: :failed

  defp load_current(options) do
    case Keyword.fetch(options, :current) do
      {:ok, current} -> current
      :error -> Keyword.get(options, :load_current, fn -> nil end).()
    end
  catch
    _kind, _reason -> nil
  end

  defp public_error(reason) when is_atom(reason), do: reason
  defp public_error({reason, _private}) when is_atom(reason), do: reason
  defp public_error(_reason), do: :operation_failed
  defp now, do: System.monotonic_time(:millisecond)

  defp offline(state, reason) do
    %Status{
      state: state,
      interface: nil,
      online: false,
      ready: false,
      reason: reason,
      checks: %{}
    }
  end

  defp public_status(state), do: %{state.observed | state: state.phase}

  defp publish_state(state) do
    state.publisher.(public_status(state))
    state
  end

  defp schedule_tick(state), do: Process.send_after(self(), :tick, state.poll_interval)
  defp configured_adapter, do: Application.fetch_env!(:nerves_gate, :internet_adapter)

  defp publish(status) do
    case NervesGate.DeviceState.publish({:state_reported, :internet, status}) do
      :ok -> :ok
      {:error, :shutting_down} -> :ok
      {:error, reason} -> raise "Internet DeviceState publication failed: #{inspect(reason)}"
    end
  end
end
