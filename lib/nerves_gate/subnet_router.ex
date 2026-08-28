defmodule NervesGate.SubnetRouter do
  @moduledoc """
  Owns desired Tailscale route advertisement and reconciles it asynchronously.

  The process is a serialized desired-state reconciler, not a workflow FSM.
  One bounded route write may run at a time; newer desired values are coalesced.
  """

  use GenServer

  alias NervesGate.FSM.Effect
  alias NervesGate.Reconciliation
  alias NervesGate.SubnetRouter.Status

  @retry_delay 30_000
  @tick_interval 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    state = Keyword.get_lazy(options, :payload, &new/0)
    GenServer.start_link(__MODULE__, state, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    %{
      phase: :disabled,
      desired: %{enabled: false, routes: []},
      observed: unavailable_observation(),
      tailnet_state: Keyword.get(options, :initial_tailnet),
      tailnet: Keyword.get(options, :tailnet, &NervesGate.Tailnet.status/0),
      apply: Keyword.get(options, :apply, &apply_routes/2),
      publisher: Keyword.get(options, :publisher, &publish/1),
      retry_delay: Keyword.get(options, :retry_delay, @retry_delay),
      effect_timeout: Keyword.get(options, :effect_timeout, 45_000),
      revision: 0,
      effect: nil,
      last_error: nil,
      attempt: 0,
      retry_at: nil,
      blocked_by: nil
    }
  end

  @spec configure(boolean(), [String.t()], GenServer.server(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def configure(enabled, routes, server \\ __MODULE__, _options \\ [])
      when is_boolean(enabled) and is_list(routes) do
    case GenServer.call(server, {:configure, enabled, routes}) do
      :ok -> {:ok, routes}
      {:error, _reason} = error -> error
    end
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec heal(GenServer.server()) :: :ok
  def heal(server \\ __MODULE__) do
    GenServer.cast(server, :heal)
    :ok
  end

  @spec status(GenServer.server()) :: Status.t()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _reason -> disabled_status()
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
    state = refresh_tailnet(state) |> resolve_observation()
    publish_state(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:configure, enabled, routes}, _from, state) do
    desired = %{enabled: enabled, routes: routes}
    state = state |> set_desired(desired) |> apply_or_block()
    publish_state(state)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}
  def handle_call(:diagnostics, _from, state), do: {:reply, diagnostic_view(state), state}
  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(:heal, state) do
    state = apply_or_block(state)
    publish_state(state)
    {:noreply, state}
  end

  def handle_cast(
        {:routes_application_completed, {ref, outcome}},
        %{effect: %{ref: ref, revision: revision}} = state
      ) do
    state = complete_application(outcome, revision, %{state | effect: nil})
    publish_state(state)
    {:noreply, state}
  end

  def handle_cast({:routes_application_completed, _stale}, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, state) do
    schedule_tick()
    state = state |> refresh_tailnet() |> reconcile_dependency()
    publish_state(state)
    {:noreply, state}
  end

  defp apply_or_block(%{effect: effect} = state) when not is_nil(effect), do: state

  defp apply_or_block(state) do
    if state.desired.enabled and not tailnet_online?(state) do
      Map.merge(state, %{phase: :blocked, blocked_by: :tailnet})
    else
      start_application(state)
    end
  end

  defp start_application(state) do
    ref = make_ref()
    revision = state.revision

    case Effect.start(
           self(),
           ref,
           fn -> {revision, state.apply.(state.desired.enabled, state.desired.routes)} end,
           fn ref, outcome -> {:routes_application_completed, {ref, outcome}} end,
           timeout: state.effect_timeout
         ) do
      {:ok, _coordinator} ->
        %{state | phase: :applying, effect: %{ref: ref, revision: revision}, blocked_by: nil}

      {:error, reason} ->
        enter_backoff(state, {:route_effect_launch_failed, Reconciliation.public_error(reason)})
    end
  end

  defp complete_application({:returned, {revision, result}}, revision, state) do
    if revision != state.revision do
      apply_or_block(state)
    else
      resolve_application_result(result, state)
    end
  end

  defp complete_application(:timed_out, _revision, state),
    do: enter_backoff(state, :route_application_timed_out)

  defp complete_application(:cancelled, _revision, state),
    do: enter_backoff(state, :route_application_cancelled)

  defp complete_application({:crashed, _kind, reason, _stack}, _revision, state),
    do: enter_backoff(state, {:route_application_crashed, Reconciliation.public_error(reason)})

  defp complete_application(_invalid, _revision, state),
    do: enter_backoff(state, :invalid_route_application_result)

  defp resolve_application_result({:ok, _applied}, state) do
    state
    |> Map.merge(%{last_error: nil, attempt: 0, retry_at: nil})
    |> refresh_tailnet()
    |> resolve_observation()
  end

  defp resolve_application_result({:error, reason}, state),
    do: enter_backoff(state, {:route_apply_failed, Reconciliation.public_error(reason)})

  defp resolve_application_result(invalid, state),
    do: enter_backoff(state, {:invalid_route_apply_result, Reconciliation.public_error(invalid)})

  defp reconcile_dependency(%{effect: effect} = state) when not is_nil(effect), do: state

  defp reconcile_dependency(state) do
    cond do
      state.desired.enabled and not tailnet_online?(state) ->
        %{resolve_observation(state) | phase: :blocked, blocked_by: :tailnet}

      state.phase == :blocked and state.desired.enabled ->
        start_application(state)

      state.phase == :backoff and Reconciliation.due?(state.retry_at) ->
        apply_or_block(state)

      true ->
        resolve_observation(state)
    end
  end

  defp resolve_observation(state) do
    state = %{state | observed: observation(state.tailnet_state)}

    cond do
      not state.desired.enabled ->
        %{state | phase: :disabled, blocked_by: nil}

      not tailnet_online?(state) ->
        %{state | phase: :blocked, blocked_by: :tailnet}

      state.phase == :backoff and not Reconciliation.due?(state.retry_at) ->
        state

      routes_approved?(state) ->
        %{state | phase: :active, blocked_by: nil, last_error: nil}

      true ->
        %{state | phase: :awaiting_approval, blocked_by: nil}
    end
  end

  defp set_desired(state, desired) do
    if state.desired == desired,
      do: state,
      else: %{state | desired: desired, revision: state.revision + 1}
  end

  defp put_tailnet(state, status),
    do: %{state | tailnet_state: status, observed: observation(status)}

  defp refresh_tailnet(state), do: put_tailnet(state, state.tailnet.())

  defp observation(%{subnet_router: routes}) when is_map(routes), do: routes
  defp observation(_unavailable), do: unavailable_observation()
  defp tailnet_online?(state), do: match?(%{online: true}, state.tailnet_state)

  defp routes_approved?(state) do
    approved = Map.get(state.observed, :approved, [])
    Enum.all?(state.desired.routes, &(&1 in approved))
  end

  defp enter_backoff(state, error) do
    state
    |> Map.merge(Reconciliation.failed(state.attempt, state.retry_delay, error))
    |> Map.merge(%{phase: :backoff, blocked_by: nil})
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
      effect: state.effect
    }
  end

  defp public_status(state) do
    %Status{
      enabled: state.desired.enabled,
      routes: state.desired.routes,
      state: state.phase,
      observed: state.observed
    }
  end

  defp disabled_status do
    %Status{
      enabled: false,
      routes: [],
      state: :disabled,
      observed: unavailable_observation()
    }
  end

  defp unavailable_observation,
    do: %{advertised: [], approved: [], primary: [], error: :unavailable}

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)
  defp publish_state(state), do: state.publisher.(public_status(state))

  defp apply_routes(enabled, routes) do
    advertised = if enabled, do: routes, else: []

    with :ok <-
           Tailscale.await_online(timeout: 30_000, require: [:authenticated, :tailscale_ipv4]),
         :ok <- Tailscale.set(ssh: false, advertise_routes: advertised),
         {:ok, applied} <- Tailscale.advertised_routes(),
         true <- applied == advertised or enabled do
      NervesGate.Tailnet.refresh()
      {:ok, if(enabled, do: applied, else: routes)}
    else
      false -> {:error, :route_withdrawal_failed}
      {:error, _reason} = error -> error
      _failure -> {:error, :route_update_failed}
    end
  end

  defp publish(status) do
    case NervesGate.DeviceState.publish({:state_reported, :subnet_router, status}) do
      :ok -> :ok
      {:error, :shutting_down} -> :ok
      {:error, reason} -> raise "SubnetRouter DeviceState publication failed: #{inspect(reason)}"
    end
  end
end
