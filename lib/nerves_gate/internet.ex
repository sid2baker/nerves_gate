defmodule NervesGate.Internet.Status do
  @moduledoc "Secret-free public uplink reality; private observation phases are excluded."

  @enforce_keys [:state, :interface, :online, :ready, :reason, :checks]
  defstruct [:state, :interface, :online, :ready, :reason, :checks]

  @type t :: %__MODULE__{
          state: :unconfigured | :applying | :online | :offline | :backoff,
          interface: String.t() | nil,
          online: boolean(),
          ready: boolean(),
          reason: atom() | nil,
          checks: map()
        }
end

defmodule NervesGate.Internet do
  @moduledoc """
  Lifecycle and sole mutation owner for the uplink interface.

  Configuration, verification, rollback, healing, and observations execute in
  one supervised correlated worker per generation. Desired changes are
  coalesced while that generation owns the interface.
  """

  alias NervesGate.FSM.{Diagnostics, Effect, Retry}
  alias NervesGate.Internet.{Config, Connectivity, Status}

  @fsm """
  [*] --> unconfigured : boot
  unconfigured --> applying : configure
  unconfigured --> applying : restore
  unconfigured --> unconfigured : heal
  unconfigured --> observing : observe
  unconfigured --> observing : tick
  online --> applying : configure
  online --> applying : restore
  online --> applying : heal
  online --> observing : observe
  online --> observing : tick
  offline --> applying : configure
  offline --> applying : restore
  offline --> applying : heal
  offline --> offline : heal
  offline --> observing : observe
  offline --> observing : tick
  backoff --> applying : configure
  backoff --> applying : restore
  backoff --> applying : heal
  backoff --> applying : tick
  backoff --> backoff : tick
  backoff --> observing : observe
  applying --> applying : configure
  applying --> applying : restore
  applying --> applying : heal
  applying --> applying : observe
  applying --> applying : tick
  applying --> applying : configuration_completed
  applying --> unconfigured : configuration_completed
  applying --> online : configuration_completed
  applying --> offline : configuration_completed
  applying --> backoff : configuration_completed
  observing --> observing : configure
  observing --> observing : restore
  observing --> observing : heal
  observing --> observing : observe
  observing --> observing : tick
  observing --> applying : observation_completed
  observing --> unconfigured : observation_completed
  observing --> online : observation_completed
  observing --> offline : observation_completed
  observing --> backoff : observation_completed
  unconfigured --> [*] : terminate
  online --> [*] : terminate
  offline --> [*] : terminate
  backoff --> [*] : terminate
  applying --> [*] : terminate
  observing --> [*] : terminate
  """

  use NervesGate.FSM, fsm: @fsm, timer: 1_000

  @initial_retry 250
  @check_order [:physical_link, :ip_address, :default_route, :dns, :internet_https]

  @type command :: {:configure, Config.t(), timeout()} | {:restore, Config.t() | nil} | :heal
  @type event ::
          :tick
          | :observe
          | {:configuration_completed, reference(), term()}
          | {:observation_completed, reference(), term()}
  @type input :: command() | event()

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    current = Keyword.get(options, :current)

    Diagnostics.new(%{
      owner: __MODULE__,
      desired: Config.to_public(current),
      observed: offline(:unconfigured, :not_configured),
      adapter: Keyword.get(options, :adapter, configured_adapter()),
      verifier: Keyword.get(options, :verifier, &Connectivity.verify/1),
      current: current,
      pending: nil,
      checks: %{},
      last_result: nil,
      publisher: Keyword.get(options, :publisher, &publish/1),
      effect_timeout: Keyword.get(options, :effect_timeout, 45_000),
      generation: 0,
      effect: nil
    })
  end

  @spec configure(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def configure(%Config{} = config, options \\ []) do
    server = Keyword.get(options, :server, __MODULE__)
    timeout = Keyword.get(options, :timeout, 30_000)
    Diagnostics.command(server, :configure, %{config: config, timeout: timeout}, timeout + 5_000)
  end

  @spec restore(Config.t() | nil, GenServer.server()) :: :ok | {:error, term()}
  def restore(config, server \\ __MODULE__),
    do: Diagnostics.command(server, :restore, %{config: config, timeout: 0}, 35_000)

  @spec reapply(GenServer.server()) :: :ok | {:error, term()}
  def reapply(server \\ __MODULE__), do: heal(server)

  @spec heal(GenServer.server()) :: :ok | {:error, term()}
  def heal(server \\ __MODULE__), do: Diagnostics.command(server, :heal, %{}, 35_000)

  @spec poll_now(GenServer.server()) :: :ok | {:error, term()}
  def poll_now(server \\ __MODULE__), do: Diagnostics.command(server, :observe, %{}, 10_000)

  @spec status(GenServer.server()) :: Status.t()
  def status(server \\ __MODULE__) do
    case Diagnostics.state(server) do
      %Finitomata.State{current: state, payload: payload} -> public_status(state, payload)
      nil -> offline(:unconfigured, :starting)
    end
  end

  @spec configuration_status(GenServer.server()) :: map()
  def configuration_status(server \\ __MODULE__) do
    case Diagnostics.state(server) do
      %Finitomata.State{current: state, payload: payload} ->
        %{
          checks: payload.checks,
          known_good: Config.to_public(payload.current),
          verifying: state == :applying,
          pending: if(payload.pending, do: %{phase: state})
        }

      nil ->
        %{checks: %{}, known_good: nil, verifying: false, pending: nil}
    end
  end

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server \\ __MODULE__), do: server |> Diagnostics.state() |> Diagnostics.view()

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, payload) do
    state = if payload.current, do: :offline, else: :unconfigured

    finish(
      :*,
      :boot,
      :unconfigured,
      put_observation(payload, with_state(payload.observed, state))
    )
  end

  def on_transition(state, event, command, payload) when event in [:configure, :restore] do
    pending = %{
      id: command.id,
      mode: event,
      config: command.config,
      previous: previous_for(payload),
      deadline: now() + command.timeout,
      delay: @initial_retry
    }

    payload = set_pending(payload, pending)

    if state in [:applying, :observing],
      do: finish(state, event, state, payload),
      else: begin_configuration(state, event, payload)
  end

  def on_transition(:unconfigured, :heal, command, payload) do
    finish(
      :unconfigured,
      :heal,
      :unconfigured,
      result(payload, command.id, {:error, :not_configured})
    )
  end

  def on_transition(:offline, :heal, command, %{observed: %{reason: :no_carrier}} = payload) do
    finish(
      :offline,
      :heal,
      :offline,
      result(payload, command.id, {:error, :physical_link_down}),
      reason: :physical_link_down
    )
  end

  def on_transition(state, :heal, command, payload) do
    pending = %{
      id: command.id,
      mode: :heal,
      config: payload.current,
      previous: previous_for(payload),
      deadline: now() + 30_000,
      delay: @initial_retry
    }

    payload = set_pending(payload, pending)

    if state in [:applying, :observing],
      do: finish(state, :heal, state, payload),
      else: begin_configuration(state, :heal, payload)
  end

  def on_transition(:applying, event, command, payload) when event in [:observe] do
    finish(
      :applying,
      event,
      :applying,
      result(payload, command.id, {:error, :configuration_in_progress})
    )
  end

  def on_transition(:applying, :tick, _event_payload, payload),
    do: finish(:applying, :tick, :applying, payload)

  def on_transition(:observing, :observe, command, payload),
    do: finish(:observing, :observe, :observing, result(payload, command.id, :ok))

  def on_transition(:observing, :tick, _event_payload, payload),
    do: finish(:observing, :tick, :observing, payload)

  def on_transition(state, event, command, payload) when event in [:observe] do
    begin_observation(state, event, payload, command.id)
  end

  def on_transition(state, :tick, _event_payload, payload) do
    cond do
      (state == :backoff and payload.current) && Retry.due?(payload.retry_at) ->
        pending = %{
          id: nil,
          mode: :heal,
          config: payload.current,
          previous: payload.current,
          deadline: now() + 30_000,
          delay: @initial_retry
        }

        payload = set_pending(payload, pending)
        begin_configuration(state, :tick, payload)

      state == :backoff and not Retry.due?(payload.retry_at) ->
        finish(state, :tick, :backoff, payload)

      true ->
        begin_observation(state, :tick, payload, nil)
    end
  end

  def on_transition(
        :applying,
        :configuration_completed,
        {ref, outcome},
        %{effect: %{ref: ref, generation: generation}} = payload
      ) do
    payload = %{payload | effect: nil}
    complete_configuration(outcome, generation, payload)
  end

  def on_transition(:applying, :configuration_completed, _stale, _payload),
    do: {:error, :stale_effect_completion}

  def on_transition(
        :observing,
        :observation_completed,
        {ref, outcome},
        %{effect: %{ref: ref, generation: generation, command_id: command_id}} = payload
      ) do
    payload = %{payload | effect: nil}
    complete_observation(outcome, generation, command_id, payload)
  end

  def on_transition(:observing, :observation_completed, _stale, _payload),
    do: {:error, :stale_effect_completion}

  @impl Finitomata
  def on_timer(_state, %Finitomata.State{payload: payload}),
    do: {:transition, :tick, payload}

  @doc false
  def after_transition(state, payload) do
    payload.publisher.(public_status(state, payload))

    case {state, payload.effect} do
      {:applying, %{ref: ref, generation: generation}} ->
        start_effect(payload, ref, fn -> transact(payload, generation) end, fn ref, outcome ->
          {:configuration_completed, {ref, outcome}}
        end)

      {:observing, %{ref: ref, generation: generation}} ->
        start_effect(payload, ref, fn -> observe_runtime(payload, generation) end, fn ref,
                                                                                      outcome ->
          {:observation_completed, {ref, outcome}}
        end)

      _stable ->
        :ok
    end
  end

  @spec summarize(String.t() | nil, map()) :: Status.t()
  def summarize(nil, _checks), do: offline(:unconfigured, :not_configured)

  def summarize(interface, checks) do
    online = Connectivity.internet_ready?(checks)

    %Status{
      state: if(online, do: :online, else: :offline),
      interface: interface,
      online: online,
      ready: online,
      reason: if(online, do: nil, else: first_failure(checks)),
      checks: checks
    }
  end

  defp start_effect(payload, ref, work, event_builder) do
    case Effect.start(self(), ref, work, event_builder, timeout: payload.effect_timeout) do
      {:ok, _coordinator} -> :ok
      {:error, reason} -> raise "Internet effect launch failed: #{inspect(reason)}"
    end
  end

  defp transact(payload, generation) do
    pending = payload.pending

    result =
      case apply_config(payload.adapter, payload.current, pending.config) do
        :ok when pending.mode == :restore ->
          checks = verify_once(payload.verifier, pending.config)
          {:applied, pending, checks}

        :ok ->
          case verify_until(payload.verifier, pending) do
            {:ok, checks} -> {:applied, pending, checks}
            {:error, checks} -> rollback_result(payload.adapter, pending, checks)
          end

        {:error, reason} ->
          rollback_result(payload.adapter, pending, %{}, {:apply_failed, public_error(reason)})
      end

    {generation, result}
  end

  defp rollback_result(adapter, pending, checks, error \\ nil) do
    error = error || {:verification_failed, public_checks(checks)}

    case restore_previous(adapter, pending) do
      :ok -> {:rolled_back, pending, checks, error}
      {:error, reason} -> {:rollback_failed, pending, {:rollback_failed, public_error(reason)}}
    end
  end

  defp observe_runtime(payload, generation) do
    {generation, payload.current, verify_once(payload.verifier, payload.current)}
  end

  defp complete_configuration({:returned, {generation, terminal}}, generation, payload) do
    payload = apply_terminal_reality(payload, terminal)

    if generation == payload.generation do
      resolve_terminal(terminal, payload)
    else
      payload
      |> begin_effect(:configuration)
      |> then(&finish(:applying, :configuration_completed, :applying, &1))
    end
  end

  defp complete_configuration(:timed_out, _generation, payload),
    do: configuration_backoff(payload, :configuration_timed_out)

  defp complete_configuration(:cancelled, _generation, payload),
    do: configuration_backoff(payload, :configuration_cancelled)

  defp complete_configuration({:crashed, _kind, reason, _stack}, _generation, payload),
    do: configuration_backoff(payload, {:configuration_crashed, public_error(reason)})

  defp complete_configuration(_invalid, _generation, payload),
    do: configuration_backoff(payload, :invalid_configuration_result)

  defp complete_observation(
         {:returned, {generation, current, checks}},
         generation,
         command_id,
         payload
       ) do
    if generation == payload.generation do
      observed = observation(current, checks)
      to = state_for_observation(current, observed)

      payload =
        payload
        |> Map.put(:checks, checks)
        |> put_observation(observed)
        |> result(command_id, :ok)

      finish(:observing, :observation_completed, to, payload)
    else
      payload
      |> begin_effect(:configuration)
      |> then(&finish(:observing, :observation_completed, :applying, &1))
    end
  end

  defp complete_observation(:timed_out, _generation, command_id, payload),
    do: observation_failure(payload, command_id, :observation_timed_out)

  defp complete_observation(:cancelled, _generation, command_id, payload),
    do: observation_failure(payload, command_id, :observation_cancelled)

  defp complete_observation({:crashed, _kind, reason, _stack}, _generation, command_id, payload),
    do: observation_failure(payload, command_id, {:observation_crashed, public_error(reason)})

  defp complete_observation(_invalid, _generation, command_id, payload),
    do: observation_failure(payload, command_id, :invalid_observation_result)

  defp resolve_terminal({:applied, pending, checks}, payload) do
    observed = observation(pending.config, checks)
    to = state_for_observation(pending.config, observed)
    command_result = if pending.mode == :configure, do: {:ok, checks}, else: :ok

    payload =
      payload
      |> Map.merge(%{current: pending.config, pending: nil, checks: checks, last_error: nil})
      |> put_observation(observed)
      |> result(pending.id, command_result)

    finish(:applying, :configuration_completed, to, payload,
      error: nil,
      blocked_by: nil,
      attempt: 0,
      retry_at: nil
    )
  end

  defp resolve_terminal({:rolled_back, pending, checks, error}, payload) do
    observed = observation(pending.previous, verify_once(payload.verifier, pending.previous))
    to = state_for_observation(pending.previous, observed)

    payload =
      payload
      |> Map.merge(%{current: pending.previous, pending: nil, checks: checks, last_error: error})
      |> put_observation(observed)
      |> result(pending.id, command_error(pending, checks, error))

    finish(:applying, :configuration_completed, to, payload, reason: error, error: error)
  end

  defp resolve_terminal({:rollback_failed, pending, error}, payload) do
    payload =
      payload
      |> Map.merge(%{pending: nil, last_error: error})
      |> result(pending.id, {:error, error})

    configuration_backoff(payload, error)
  end

  defp apply_terminal_reality(payload, {:applied, pending, checks}) do
    %{
      payload
      | current: pending.config,
        checks: checks,
        observed: observation(pending.config, checks)
    }
  end

  defp apply_terminal_reality(payload, {:rolled_back, pending, _checks, _error}),
    do: %{payload | current: pending.previous}

  defp apply_terminal_reality(payload, {:rollback_failed, _pending, _error}), do: payload

  defp configuration_backoff(payload, error) do
    attempt = payload.attempt + 1
    pending = payload.pending

    payload =
      payload
      |> Map.put(:pending, nil)
      |> result(pending && pending.id, {:error, error})

    finish(:applying, :configuration_completed, :backoff, payload,
      reason: error,
      error: error,
      attempt: attempt,
      retry_at: now() + min(1_000 * attempt, 30_000)
    )
  end

  defp observation_failure(payload, command_id, error) do
    observed = with_state(payload.observed, :offline) |> Map.put(:reason, error)
    payload = payload |> put_observation(observed) |> result(command_id, {:error, error})
    finish(:observing, :observation_completed, :offline, payload, error: error)
  end

  defp set_pending(payload, pending) do
    previous = if payload.pending, do: payload.pending.previous, else: pending.previous
    pending = %{pending | previous: previous}

    %{
      payload
      | pending: pending,
        desired: Config.to_public(pending.config),
        generation: payload.generation + 1
    }
  end

  defp previous_for(%{pending: %{previous: previous}}), do: previous
  defp previous_for(payload), do: payload.current

  defp begin_configuration(from, event, payload) do
    payload = begin_effect(payload, :configuration)
    finish(from, event, :applying, payload)
  end

  defp begin_observation(from, event, payload, command_id) do
    effect = %{ref: make_ref(), generation: payload.generation, command_id: command_id}
    finish(from, event, :observing, %{payload | effect: effect})
  end

  defp begin_effect(payload, :configuration) do
    %{payload | effect: %{ref: make_ref(), generation: payload.generation}}
  end

  defp verify_until(verifier, pending) do
    checks = verifier.(pending.config.interface)

    cond do
      Connectivity.internet_ready?(checks) ->
        {:ok, checks}

      now() >= pending.deadline ->
        {:error, checks}

      true ->
        {wait, next_delay} = Retry.next(pending.delay, 4_000)
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

  defp put_observation(payload, observed), do: %{payload | observed: observed}

  defp finish(from, event, to, payload, options \\ []) do
    {:ok, to, Diagnostics.record(payload, from, event, to, options)}
  end

  defp result(payload, nil, _result), do: payload
  defp result(payload, id, value), do: %{payload | last_result: {id, value}}

  defp command_error(%{mode: :configure}, checks, _error),
    do: {:error, {:verification_failed, checks}}

  defp command_error(%{mode: :heal}, _checks, _error),
    do: {:error, :connectivity_unavailable}

  defp command_error(%{mode: :restore}, _checks, error), do: {:error, error}

  defp state_for_observation(nil, _observed), do: :unconfigured
  defp state_for_observation(_current, %{online: true}), do: :online
  defp state_for_observation(_current, _observed), do: :offline

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
  defp public_check({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp public_check(_value), do: {:error, :failed}
  defp public_error(reason) when is_atom(reason), do: reason
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

  # Passive observations do not replace known public reality with an internal
  # worker phase. This keeps routine polling from publishing online/observing
  # oscillations while preserving :observing in private diagnostics.
  defp public_status(:observing, payload), do: payload.observed
  defp public_status(state, payload), do: with_state(payload.observed, state)

  defp with_state(%Status{} = status, state), do: %{status | state: state}
  defp configured_adapter, do: Application.fetch_env!(:nerves_gate, :internet_adapter)

  defp publish(status) do
    case NervesGate.DeviceState.publish({:state_reported, :internet, status}) do
      :ok -> :ok
      {:error, :shutting_down} -> :ok
      {:error, reason} -> raise "Internet DeviceState publication failed: #{inspect(reason)}"
    end
  end
end
