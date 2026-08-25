defmodule NervesGate.SubnetRouter.Status do
  @moduledoc "Secret-free public subnet-router state."

  @enforce_keys [:enabled, :routes, :state, :observed]
  defstruct [:enabled, :routes, :state, :observed, :applied_change_id, :failed_change_id]

  @type t :: %__MODULE__{
          enabled: boolean(),
          routes: [String.t()],
          state: :disabled | :blocked | :applying | :awaiting_approval | :active | :backoff,
          observed: map(),
          applied_change_id: String.t() | nil,
          failed_change_id: String.t() | nil
        }
end

defmodule NervesGate.SubnetRouter do
  @moduledoc """
  Lifecycle and mutation owner for Tailscale route advertisement.

  Route writes are serialized. A newer desired route set is coalesced while the
  active generation runs and is applied immediately after that generation's
  terminal event.
  """

  alias NervesGate.FSM.{Diagnostics, Effect, Retry}
  alias NervesGate.SubnetRouter.{Routes, Status}

  @fsm """
  [*] --> disabled : boot
  disabled --> applying : configure
  disabled --> blocked : configure
  disabled --> disabled : retry_timer_fired
  disabled --> disabled : tailnet_state_changed
  disabled --> disabled : heal
  blocked --> applying : configure
  blocked --> blocked : configure
  blocked --> applying : retry_timer_fired
  blocked --> applying : tailnet_state_changed
  blocked --> applying : heal
  blocked --> blocked : retry_timer_fired
  blocked --> blocked : tailnet_state_changed
  blocked --> blocked : heal
  awaiting_approval --> applying : configure
  awaiting_approval --> blocked : configure
  awaiting_approval --> applying : heal
  awaiting_approval --> active : tailnet_state_changed
  awaiting_approval --> awaiting_approval : tailnet_state_changed
  awaiting_approval --> blocked : tailnet_state_changed
  awaiting_approval --> active : retry_timer_fired
  awaiting_approval --> awaiting_approval : retry_timer_fired
  awaiting_approval --> blocked : retry_timer_fired
  active --> applying : configure
  active --> blocked : configure
  active --> applying : heal
  active --> active : tailnet_state_changed
  active --> awaiting_approval : tailnet_state_changed
  active --> blocked : tailnet_state_changed
  active --> active : retry_timer_fired
  active --> awaiting_approval : retry_timer_fired
  active --> blocked : retry_timer_fired
  backoff --> applying : configure
  backoff --> blocked : configure
  backoff --> applying : heal
  backoff --> applying : retry_timer_fired
  backoff --> applying : tailnet_state_changed
  backoff --> backoff : retry_timer_fired
  backoff --> blocked : retry_timer_fired
  backoff --> blocked : tailnet_state_changed
  applying --> applying : configure
  applying --> applying : heal
  applying --> applying : retry_timer_fired
  applying --> applying : tailnet_state_changed
  applying --> applying : routes_application_completed
  applying --> disabled : routes_application_completed
  applying --> blocked : routes_application_completed
  applying --> awaiting_approval : routes_application_completed
  applying --> active : routes_application_completed
  applying --> backoff : routes_application_completed
  disabled --> [*] : terminate
  """

  use NervesGate.FSM, fsm: @fsm, timer: 1_000

  @retry_delay 30_000

  @type command :: {:configure, boolean(), [String.t()], String.t() | nil} | :heal
  @type event ::
          :retry_timer_fired
          | {:tailnet_state_changed, map()}
          | {:routes_application_completed, reference(), term()}
  @type input :: command() | event()

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    Diagnostics.new(%{
      owner: __MODULE__,
      desired: %{enabled: false, routes: [], change_id: nil},
      observed: unavailable_observation(),
      tailnet_state: Keyword.get(options, :initial_tailnet),
      tailnet: Keyword.get(options, :tailnet, &NervesGate.Tailnet.status/0),
      apply: Keyword.get(options, :apply, &Routes.apply/2),
      publisher: Keyword.get(options, :publisher, &publish/1),
      retry_delay: Keyword.get(options, :retry_delay, @retry_delay),
      effect_timeout: Keyword.get(options, :effect_timeout, 45_000),
      generation: 0,
      effect: nil,
      applied_change_id: nil,
      failed_change_id: nil,
      last_result: nil
    })
  end

  @spec configure(boolean(), [String.t()], GenServer.server(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def configure(enabled, routes, server \\ __MODULE__, options \\ [])
      when is_boolean(enabled) and is_list(routes) do
    change_id = Keyword.get(options, :change_id)

    GenServer.cast(
      server,
      {:configure, %{enabled: enabled, routes: routes, change_id: change_id}}
    )

    {:ok, routes}
  end

  @spec heal(GenServer.server()) :: :ok
  def heal(server \\ __MODULE__) do
    GenServer.cast(server, {:heal, nil})
    :ok
  end

  @spec tailnet_state_changed(map(), GenServer.server()) :: :ok
  def tailnet_state_changed(status, server \\ __MODULE__) do
    GenServer.cast(server, {:tailnet_state_changed, status})
    :ok
  end

  @spec status(GenServer.server()) :: Status.t()
  def status(server \\ __MODULE__) do
    case Diagnostics.state(server) do
      %Finitomata.State{current: state, payload: payload} -> public_status(state, payload)
      nil -> public_status(:disabled, new())
    end
  end

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server \\ __MODULE__), do: server |> Diagnostics.state() |> Diagnostics.view()

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, payload) do
    payload = refresh_tailnet(payload)
    finish(:*, :boot, :disabled, payload)
  end

  def on_transition(state, :configure, command, payload) do
    desired = %{enabled: command.enabled, routes: command.routes, change_id: command.change_id}
    payload = set_desired(payload, desired)

    if state == :applying,
      do: finish(state, :configure, :applying, payload),
      else: start_application(state, :configure, payload)
  end

  def on_transition(:applying, :heal, _event_payload, payload),
    do: finish(:applying, :heal, :applying, payload)

  def on_transition(state, :heal, _event_payload, payload),
    do: start_application(state, :heal, payload)

  def on_transition(state, :tailnet_state_changed, status, payload) do
    payload = put_tailnet(payload, status)

    cond do
      state == :applying ->
        finish(state, :tailnet_state_changed, :applying, payload)

      state == :blocked and payload.desired.enabled and tailnet_online?(payload) ->
        start_application(state, :tailnet_state_changed, payload)

      state == :backoff and Retry.due?(payload.retry_at) and tailnet_online?(payload) ->
        start_application(state, :tailnet_state_changed, payload)

      true ->
        resolve_observation(state, :tailnet_state_changed, payload)
    end
  end

  def on_transition(:applying, :retry_timer_fired, _event_payload, payload),
    do: finish(:applying, :retry_timer_fired, :applying, payload)

  def on_transition(state, :retry_timer_fired, _event_payload, payload) do
    payload = refresh_tailnet(payload)

    cond do
      state == :blocked and payload.desired.enabled and tailnet_online?(payload) ->
        start_application(state, :retry_timer_fired, payload)

      state == :backoff and Retry.due?(payload.retry_at) ->
        start_application(state, :retry_timer_fired, payload)

      true ->
        resolve_observation(state, :retry_timer_fired, payload)
    end
  end

  def on_transition(
        :applying,
        :routes_application_completed,
        {ref, outcome},
        %{effect: %{ref: ref, generation: generation}} = payload
      ) do
    payload = %{payload | effect: nil}
    handle_application(outcome, generation, payload)
  end

  def on_transition(:applying, :routes_application_completed, {_stale, _outcome}, _payload),
    do: {:error, :stale_effect_completion}

  @impl Finitomata
  def on_timer(_state, %Finitomata.State{payload: payload}),
    do: {:transition, :retry_timer_fired, payload}

  @doc false
  def after_transition(state, payload) do
    payload.publisher.(public_status(state, payload))
    launch_application(state, payload)
  end

  defp launch_application(:applying, %{effect: %{ref: ref, generation: generation}} = payload) do
    case Effect.start(
           self(),
           ref,
           fn ->
             {generation, payload.apply.(payload.desired.enabled, payload.desired.routes)}
           end,
           fn ref, outcome -> {:routes_application_completed, {ref, outcome}} end,
           timeout: payload.effect_timeout
         ) do
      {:ok, _coordinator} -> :ok
      {:error, reason} -> raise "SubnetRouter effect launch failed: #{inspect(reason)}"
    end
  end

  defp launch_application(_state, _payload), do: :ok

  defp handle_application({:returned, {generation, result}}, generation, payload) do
    if generation != payload.generation do
      payload
      |> begin_effect()
      |> then(&finish(:applying, :routes_application_completed, :applying, &1))
    else
      resolve_application_result(result, payload)
    end
  end

  defp handle_application(:timed_out, _generation, payload),
    do: enter_backoff(payload, :route_application_timed_out)

  defp handle_application(:cancelled, _generation, payload),
    do: enter_backoff(payload, :route_application_cancelled)

  defp handle_application({:crashed, _kind, reason, _stack}, _generation, payload),
    do: enter_backoff(payload, {:route_application_crashed, Retry.public_error(reason)})

  defp handle_application(_invalid, _generation, payload),
    do: enter_backoff(payload, :invalid_route_application_result)

  defp resolve_application_result({:ok, _applied}, payload) do
    payload = %{
      payload
      | applied_change_id: payload.desired.change_id,
        failed_change_id: nil,
        last_error: nil,
        attempt: 0,
        retry_at: nil
    }

    resolve_observation(:applying, :routes_application_completed, refresh_tailnet(payload))
  end

  defp resolve_application_result({:error, reason}, payload) do
    payload = %{payload | failed_change_id: payload.desired.change_id}
    enter_backoff(payload, {:route_apply_failed, Retry.public_error(reason)})
  end

  defp resolve_application_result(invalid, payload),
    do: enter_backoff(payload, {:invalid_route_apply_result, Retry.public_error(invalid)})

  defp start_application(state, event, payload) do
    if payload.desired.enabled and not tailnet_online?(payload) do
      payload = %{
        payload
        | applied_change_id: payload.desired.change_id,
          failed_change_id: nil
      }

      finish(state, event, :blocked, payload, blocked_by: :tailnet)
    else
      payload = begin_effect(payload)
      finish(state, event, :applying, payload, blocked_by: nil)
    end
  end

  defp resolve_observation(state, event, payload) do
    payload = observe_routes(payload)

    cond do
      not payload.desired.enabled ->
        finish(state, event, :disabled, payload, error: nil, blocked_by: nil)

      not tailnet_online?(payload) ->
        finish(state, event, :blocked, payload, blocked_by: :tailnet)

      state == :backoff and not Retry.due?(payload.retry_at) ->
        finish(state, event, :backoff, payload)

      routes_approved?(payload) ->
        finish(state, event, :active, payload, error: nil, blocked_by: nil)

      true ->
        finish(state, event, :awaiting_approval, payload)
    end
  end

  defp begin_effect(payload),
    do: %{payload | effect: %{ref: make_ref(), generation: payload.generation}}

  defp set_desired(payload, desired) do
    if payload.desired == desired,
      do: payload,
      else: %{payload | desired: desired, generation: payload.generation + 1}
  end

  defp put_tailnet(payload, status) do
    %{payload | tailnet_state: status, observed: observation(status)}
  end

  defp refresh_tailnet(payload), do: put_tailnet(payload, payload.tailnet.())

  defp observe_routes(payload), do: %{payload | observed: observation(payload.tailnet_state)}
  defp observation(%{subnet_router: routes}) when is_map(routes), do: routes
  defp observation(_unavailable), do: unavailable_observation()
  defp tailnet_online?(payload), do: match?(%{online: true}, payload.tailnet_state)

  defp routes_approved?(payload) do
    approved = Map.get(payload.observed, :approved, [])
    Enum.all?(payload.desired.routes, &(&1 in approved))
  end

  defp enter_backoff(payload, error) do
    attempt = payload.attempt + 1

    finish(:applying, :routes_application_completed, :backoff, payload,
      reason: error,
      error: error,
      attempt: attempt,
      retry_at: Retry.now() + payload.retry_delay
    )
  end

  defp finish(from, event, to, payload, options \\ []) do
    {:ok, to, Diagnostics.record(payload, from, event, to, options)}
  end

  defp public_status(state, payload) do
    %Status{
      enabled: payload.desired.enabled,
      routes: payload.desired.routes,
      state: state,
      observed: payload.observed,
      applied_change_id: payload.applied_change_id,
      failed_change_id: payload.failed_change_id
    }
  end

  defp unavailable_observation,
    do: %{advertised: [], approved: [], primary: [], error: :unavailable}

  defp publish(status) do
    case NervesGate.DeviceState.publish({:state_reported, :subnet_router, status}) do
      :ok -> :ok
      {:error, :shutting_down} -> :ok
      {:error, reason} -> raise "SubnetRouter DeviceState publication failed: #{inspect(reason)}"
    end
  end
end

defmodule NervesGate.SubnetRouter.Routes do
  @moduledoc "Idempotent Tailscale route-advertisement boundary."

  alias NervesGate.Tailnet, as: Tailnet

  @spec apply(boolean(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def apply(enabled, routes) do
    advertised = if enabled, do: routes, else: []

    with :ok <-
           Tailscale.await_online(timeout: 30_000, require: [:authenticated, :tailscale_ipv4]),
         :ok <- Tailscale.set(ssh: false, advertise_routes: advertised),
         {:ok, applied} <- Tailscale.advertised_routes(),
         true <- applied == advertised or enabled do
      Tailnet.refresh()
      {:ok, if(enabled, do: applied, else: routes)}
    else
      false -> {:error, :route_withdrawal_failed}
      {:error, _reason} = error -> error
      _failure -> {:error, :route_update_failed}
    end
  end
end
