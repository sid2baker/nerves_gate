defmodule NervesGate.SSH do
  @moduledoc """
  Owns and reconciles the single Tailnet-only NervesSSH listener.

  Desired changes are acknowledged immediately. At most one supervised runtime
  mutation is active; changes arriving during it increment the desired revision
  and converge after the active mutation terminates.
  """

  use GenServer

  alias NervesGate.FSM.Effect
  alias NervesGate.Reconciliation
  alias NervesGate.SSH.{Runtime, Status}

  @retry_delay 1_000
  @tick_interval 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    state = Keyword.get_lazy(options, :payload, fn -> new(options) end)
    GenServer.start_link(__MODULE__, state, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    runtime = %{
      address: Keyword.get(options, :address, &Runtime.address/1),
      valid?: Keyword.get(options, :valid?, &Runtime.listener_valid?/2),
      start: Keyword.get(options, :starter, &Runtime.start/1),
      stop: Keyword.get(options, :stopper, &Runtime.stop/1),
      observe: Keyword.get(options, :observer, &Runtime.observe/1),
      port: Keyword.get(options, :port, Runtime.port())
    }

    %{
      phase: :disabled,
      desired: %{enabled: Keyword.get(options, :enabled, false)},
      observed: %{listener: nil, tailnet: Keyword.get(options, :initial_tailnet)},
      tailnet: Keyword.get(options, :tailnet, &NervesGate.Tailnet.status/0),
      runtime: runtime,
      publisher: Keyword.get(options, :publisher, &publish/1),
      load_enabled: Keyword.get(options, :load_enabled, fn -> false end),
      retry_delay: Keyword.get(options, :retry_delay, @retry_delay),
      effect_timeout: Keyword.get(options, :effect_timeout, 30_000),
      revision: 0,
      effect: nil,
      last_error: nil,
      blocked_by: nil,
      attempt: 0,
      retry_at: nil
    }
  end

  @spec set_enabled(boolean(), GenServer.server()) :: :ok | {:error, term()}
  def set_enabled(enabled, server \\ __MODULE__) when is_boolean(enabled) do
    GenServer.call(server, {:set_enabled, enabled})
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec heal(GenServer.server()) :: :ok | {:error, term()}
  def heal(server \\ __MODULE__) do
    GenServer.call(server, :heal)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec status(GenServer.server()) :: Status.t()
  def status(server \\ __MODULE__) do
    case query(server, :status) do
      {:ok, status} -> status
      :unavailable -> disabled_status()
    end
  end

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server \\ __MODULE__) do
    case query(server, :diagnostics) do
      {:ok, diagnostics} -> diagnostics
      :unavailable -> nil
    end
  end

  @impl true
  def init(state) do
    schedule_tick()
    state = state |> restore_desired() |> refresh_tailnet()
    publish_state(state)
    send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_call({:set_enabled, enabled}, _from, state) do
    state = set_desired(state, enabled) |> reconcile()
    publish_state(state)
    {:reply, :ok, state}
  end

  def handle_call(:heal, _from, state) do
    state = reconcile(state, force: true)
    publish_state(state)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}
  def handle_call(:diagnostics, _from, state), do: {:reply, diagnostic_view(state), state}
  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(
        {:reconciliation_completed, {ref, outcome}},
        %{effect: %{ref: ref, revision: revision}} = state
      ) do
    state = complete_reconciliation(outcome, revision, %{state | effect: nil})
    publish_state(state)
    {:noreply, state}
  end

  def handle_cast({:reconciliation_completed, _stale}, state), do: {:noreply, state}

  @impl true
  def handle_info(:reconcile, state) do
    state = reconcile(state)
    publish_state(state)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    schedule_tick()
    state = state |> refresh_tailnet() |> reconcile()
    publish_state(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    stop_actual(state, state.observed.listener)
    :ok
  end

  defp reconcile(state, options \\ [])

  defp reconcile(%{effect: effect} = state, _options) when not is_nil(effect), do: state

  defp reconcile(state, options) do
    force = Keyword.get(options, :force, false)
    listener = state.observed.listener
    address = tailnet_address(state)

    case reconciliation_decision(state, listener, address, force) do
      {:stable, phase} -> stable(state, phase)
      :wait -> state
      :reconcile -> start_reconciliation(state)
    end
  end

  defp reconciliation_decision(%{desired: %{enabled: false}}, nil, _address, _force),
    do: {:stable, :disabled}

  defp reconciliation_decision(%{desired: %{enabled: true}}, nil, nil, _force),
    do: {:stable, :blocked}

  defp reconciliation_decision(state, listener, address, false) do
    if listener_matches?(state, listener, address),
      do: {:stable, :listening},
      else: retry_decision(state)
  end

  defp reconciliation_decision(_state, _listener, _address, true), do: :reconcile

  defp retry_decision(%{phase: :backoff, retry_at: retry_at}) do
    if Reconciliation.due?(retry_at), do: :reconcile, else: :wait
  end

  defp retry_decision(_state), do: :reconcile

  defp start_reconciliation(state) do
    ref = make_ref()
    revision = state.revision
    owner = self()

    case Effect.start(
           owner,
           ref,
           fn -> {revision, reconcile_runtime(state)} end,
           fn ref, outcome -> {:reconciliation_completed, {ref, outcome}} end,
           timeout: state.effect_timeout
         ) do
      {:ok, _coordinator} ->
        %{state | phase: :reconciling, effect: %{ref: ref, revision: revision}}

      {:error, reason} ->
        enter_backoff(
          state,
          {:listener_effect_launch_failed, Reconciliation.public_error(reason)}
        )
    end
  end

  defp reconcile_runtime(state) do
    address = tailnet_address(state)
    actual = state.observed.listener || state.runtime.observe.(address)

    cond do
      not state.desired.enabled ->
        stop_actual(state, actual)
        {:ok, nil}

      is_nil(address) ->
        stop_actual(state, actual)
        {:blocked, :tailnet}

      state.runtime.valid?.(actual, address) ->
        {:ok, actual}

      true ->
        stop_actual(state, actual)

        case state.runtime.start.(address) do
          {:ok, pid} when is_pid(pid) -> {:ok, %{pid: pid, address: address}}
          {:error, reason} -> {:error, reason}
          invalid -> {:error, {:invalid_listener_start_result, invalid}}
        end
    end
  end

  defp complete_reconciliation({:returned, {revision, result}}, revision, state) do
    state = apply_runtime_result(state, result)

    if revision == state.revision,
      do: resolve_result(state, result),
      else: reconcile(state, force: true)
  end

  defp complete_reconciliation(:timed_out, _revision, state),
    do: enter_backoff(state, :listener_reconciliation_timed_out)

  defp complete_reconciliation(:cancelled, _revision, state),
    do: enter_backoff(state, :listener_reconciliation_cancelled)

  defp complete_reconciliation({:crashed, _kind, reason, _stack}, _revision, state),
    do:
      enter_backoff(
        state,
        {:listener_reconciliation_crashed, Reconciliation.public_error(reason)}
      )

  defp complete_reconciliation(_invalid, _revision, state),
    do: enter_backoff(state, :invalid_listener_reconciliation_result)

  defp resolve_result(state, {:ok, nil}), do: stable(state, :disabled)
  defp resolve_result(state, {:ok, _listener}), do: stable(state, :listening)
  defp resolve_result(state, {:blocked, :tailnet}), do: stable(state, :blocked)

  defp resolve_result(state, {:error, reason}),
    do: enter_backoff(state, {:listener_start_failed, Reconciliation.public_error(reason)})

  defp apply_runtime_result(state, {:ok, listener}),
    do: put_in(state, [:observed, :listener], listener)

  defp apply_runtime_result(state, _failure),
    do: put_in(state, [:observed, :listener], nil)

  defp set_desired(state, enabled) do
    revision = if state.desired.enabled == enabled, do: state.revision, else: state.revision + 1
    %{state | desired: %{enabled: enabled}, revision: revision}
  end

  defp put_tailnet(state, tailnet) do
    if state.observed.tailnet == tailnet do
      state
    else
      state
      |> put_in([:observed, :tailnet], tailnet)
      |> Map.update!(:revision, &(&1 + 1))
    end
  end

  defp restore_desired(state) do
    case state.load_enabled.() do
      enabled when is_boolean(enabled) -> put_in(state, [:desired, :enabled], enabled)
      _invalid -> state
    end
  catch
    _kind, _reason -> state
  end

  defp refresh_tailnet(state) do
    put_tailnet(state, state.tailnet.())
  catch
    :exit, _reason -> state
  end

  defp stable(state, phase) do
    blocked_by = if phase == :blocked, do: :tailnet

    state
    |> Map.merge(Reconciliation.converged())
    |> Map.merge(%{phase: phase, blocked_by: blocked_by})
  end

  defp enter_backoff(state, error) do
    state
    |> Map.merge(Reconciliation.failed(state.attempt, state.retry_delay, error))
    |> Map.merge(%{phase: :backoff, blocked_by: nil})
  end

  defp stop_actual(_state, nil), do: :ok
  defp stop_actual(state, %{pid: pid}), do: state.runtime.stop.(pid)
  defp listener_matches?(_state, nil, _address), do: false
  defp listener_matches?(_state, _listener, nil), do: false
  defp listener_matches?(state, listener, address), do: state.runtime.valid?.(listener, address)
  defp tailnet_address(state), do: state.runtime.address.(state.observed.tailnet || %{})

  defp diagnostic_view(state) do
    %{
      state: state.phase,
      desired: state.desired,
      observed: state.observed,
      blocked_by: Map.get(state, :blocked_by),
      last_error: state.last_error,
      attempt: state.attempt,
      retry_at: state.retry_at,
      effect: state.effect
    }
  end

  defp public_status(state) do
    listener = state.observed.listener

    %Status{
      enabled: state.desired.enabled,
      state: state.phase,
      address: if(state.phase == :listening and listener, do: encode_address(listener.address)),
      port: state.runtime.port
    }
  end

  defp disabled_status do
    %Status{
      enabled: false,
      state: :disabled,
      address: nil,
      port: Runtime.port()
    }
  end

  defp query(server, message) do
    {:ok, GenServer.call(server, message)}
  catch
    :exit, _reason -> :unavailable
  end

  defp publish_state(state), do: state.publisher.(public_status(state))
  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)
  defp encode_address(address), do: address |> :inet.ntoa() |> List.to_string()

  defp publish(status) do
    case NervesGate.DeviceState.publish({:state_reported, :ssh, status}) do
      :ok -> :ok
      {:error, :shutting_down} -> :ok
      {:error, reason} -> raise "SSH DeviceState publication failed: #{inspect(reason)}"
    end
  end
end
