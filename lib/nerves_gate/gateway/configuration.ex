defmodule NervesGate.Gateway.Configuration do
  @moduledoc "Owns durable accepted settings and the complete staged configuration transaction."

  alias NervesGate.Cluster, as: Cluster
  alias NervesGate.FSM.{Diagnostics, Effect}
  alias NervesGate.Gateway.Configuration.Context
  alias NervesGate.Gateway.Persistence
  alias NervesGate.Gateway.Runtime
  alias NervesGate.Gateway.Settings
  alias NervesGate.Storage

  @slots ["a", "b"]
  @default_timeout :timer.minutes(1)

  @fsm """
  [*] --> activating : boot
  activating --> idle : activation_completed
  activating --> activating : tick
  activating --> activating : public_state_requested
  activating --> activating : runtime_state_changed
  activating --> [*] : terminate
  idle --> awaiting_runtime_change : resume_runtime_change
  awaiting_runtime_change --> awaiting_runtime_change : resume_runtime_change
  idle --> executing_change : stage_internet
  idle --> executing_change : begin_tailnet_change
  idle --> executing_change : begin_cluster_change
  needs_tailnet --> executing_change : update_internet
  needs_cluster --> executing_change : update_internet
  needs_confirmation --> executing_change : update_internet
  needs_tailnet --> executing_change : stage_tailnet
  needs_cluster --> executing_change : stage_tailnet
  needs_confirmation --> executing_change : stage_tailnet
  needs_cluster --> executing_change : stage_cluster
  needs_confirmation --> executing_change : stage_cluster
  needs_confirmation --> executing_change : confirm
  needs_tailnet --> executing_change : revert
  needs_cluster --> executing_change : revert
  needs_confirmation --> executing_change : revert
  needs_tailnet --> needs_tailnet : tick
  needs_tailnet --> executing_change : tick
  needs_cluster --> needs_cluster : tick
  needs_cluster --> executing_change : tick
  needs_confirmation --> needs_confirmation : tick
  needs_confirmation --> executing_change : tick
  executing_change --> idle : configuration_step_completed
  executing_change --> needs_tailnet : configuration_step_completed
  executing_change --> needs_cluster : configuration_step_completed
  executing_change --> needs_confirmation : configuration_step_completed
  executing_change --> executing_change : tick
  executing_change --> executing_change : public_state_requested
  executing_change --> [*] : terminate
  idle --> idle : tick
  idle --> persisting_runtime_change : configure_subnet_router
  idle --> persisting_runtime_change : configure_ssh
  idle --> idle : configure_subnet_router
  idle --> idle : configure_ssh
  idle --> idle : heal
  idle --> awaiting_runtime_change : heal
  idle --> idle : runtime_state_changed
  persisting_runtime_change --> awaiting_runtime_change : runtime_change_persistence_completed
  persisting_runtime_change --> idle : runtime_change_persistence_completed
  awaiting_runtime_change --> awaiting_runtime_change : runtime_command_finished
  awaiting_runtime_change --> finalizing_runtime_change : runtime_command_finished
  finalizing_runtime_change --> finalizing_runtime_change : runtime_command_finished
  awaiting_runtime_change --> awaiting_runtime_change : runtime_state_changed
  awaiting_runtime_change --> finalizing_runtime_change : runtime_state_changed
  finalizing_runtime_change --> idle : runtime_change_persistence_completed
  persisting_runtime_change --> persisting_runtime_change : tick
  awaiting_runtime_change --> awaiting_runtime_change : tick
  finalizing_runtime_change --> finalizing_runtime_change : tick
  needs_tailnet --> needs_tailnet : heal
  needs_cluster --> needs_cluster : heal
  needs_confirmation --> needs_confirmation : heal
  idle --> idle : public_state_requested
  needs_tailnet --> needs_tailnet : public_state_requested
  needs_cluster --> needs_cluster : public_state_requested
  needs_confirmation --> needs_confirmation : public_state_requested
  persisting_runtime_change --> persisting_runtime_change : public_state_requested
  awaiting_runtime_change --> awaiting_runtime_change : public_state_requested
  finalizing_runtime_change --> finalizing_runtime_change : public_state_requested
  idle --> [*] : terminate
  persisting_runtime_change --> [*] : terminate
  awaiting_runtime_change --> [*] : terminate
  finalizing_runtime_change --> [*] : terminate
  """

  use NervesGate.FSM, fsm: @fsm, timer: 500

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    root = Keyword.get(options, :root, Storage.root())
    firmware = Keyword.get(options, :firmware, &firmware_metadata/0).()

    hydration =
      case Persistence.hydrate(root, firmware) do
        {:ok, hydration} -> hydration
        {:error, reason} -> raise "gateway settings unavailable: #{inspect(reason)}"
      end

    Diagnostics.new(%{
      owner: __MODULE__,
      desired: Settings.public(hydration.current),
      observed: nil,
      root: root,
      firmware: hydration.firmware,
      current: hydration.current,
      recovered_candidate: hydration.candidate,
      pending: nil,
      runtime_change: pending_runtime_change(hydration.current),
      startup_effect: %{ref: make_ref()},
      step_effect: nil,
      ops: Map.merge(Runtime.default(), Map.new(Keyword.get(options, :ops, []))),
      keep_local_access:
        Keyword.get(
          options,
          :keep_local_access,
          Application.get_env(:nerves_gate, :local_dashboard, false)
        ),
      last_result: nil,
      effect_timeout: Keyword.get(options, :effect_timeout, 30_000),
      startup_timeout: Keyword.get(options, :startup_timeout, 120_000),
      step_timeout: Keyword.get(options, :step_timeout, 120_000),
      publisher: Keyword.get(options, :publisher, &publish_configuration/1)
    })
  end

  @spec current(GenServer.server()) :: map()
  def current(server \\ __MODULE__), do: Diagnostics.state(server).payload.current

  @spec configured?(GenServer.server()) :: boolean()
  def configured?(server \\ __MODULE__), do: current(server)["configured"]

  @spec configuration(GenServer.server()) :: map()
  def configuration(server \\ __MODULE__) do
    server |> Diagnostics.state() |> Map.fetch!(:payload) |> Context.public()
  end

  @type change_scope :: :tailnet | :cluster

  @spec begin_change(change_scope(), String.t(), pos_integer(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def begin_change(scope, source_connection, timeout \\ @default_timeout, server \\ __MODULE__)

  def begin_change(scope, source_connection, timeout, server)
      when scope in [:tailnet, :cluster] do
    event = if scope == :tailnet, do: :begin_tailnet_change, else: :begin_cluster_change

    command(server, event, %{
      scope: scope,
      source_connection: source_connection,
      timeout: timeout
    })
  end

  @spec stage_internet(map(), String.t(), pos_integer() | nil, GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def stage_internet(
        params,
        source_connection,
        timeout \\ @default_timeout,
        server \\ __MODULE__
      ) do
    command(server, :stage_internet, %{
      params: params,
      source_connection: source_connection,
      timeout: timeout
    })
  end

  @spec update_internet(String.t(), map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def update_internet(id, params, server \\ __MODULE__),
    do: command(server, :update_internet, %{change_id: id, params: params})

  @spec stage_tailnet(String.t(), map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def stage_tailnet(id, params, server \\ __MODULE__),
    do: command(server, :stage_tailnet, %{change_id: id, params: params}, 45_000)

  @spec stage_cluster(String.t(), map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def stage_cluster(id, params, server \\ __MODULE__),
    do: command(server, :stage_cluster, %{change_id: id, params: params}, 45_000)

  @spec confirm(String.t(), map(), GenServer.server()) :: :ok | {:error, term()}
  def confirm(id, connection, server \\ __MODULE__),
    do: command(server, :confirm, %{change_id: id, connection: connection}, 30_000)

  @spec revert(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def revert(id, server \\ __MODULE__),
    do: command(server, :revert, %{change_id: id}, 45_000)

  @spec configure_subnet_router(boolean(), [String.t()], GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def configure_subnet_router(enabled, routes, server \\ __MODULE__),
    do: command(server, :configure_subnet_router, %{enabled: enabled, routes: routes}, 45_000)

  @spec configure_ssh(boolean(), GenServer.server()) :: :ok | {:error, term()}
  def configure_ssh(enabled, server \\ __MODULE__),
    do: command(server, :configure_ssh, %{enabled: enabled}, 45_000)

  @spec heal(GenServer.server()) :: :ok | {:error, term()}
  def heal(server \\ __MODULE__), do: command(server, :heal, %{})

  @doc false
  @spec runtime_state_changed(:ssh | :subnet_router, map(), GenServer.server()) :: :ok
  def runtime_state_changed(source, status, server \\ __MODULE__)
      when source in [:ssh, :subnet_router] and is_map(status) do
    GenServer.cast(server, {:runtime_state_changed, %{source: source, status: status}})
    :ok
  end

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server \\ __MODULE__), do: server |> Diagnostics.state() |> Diagnostics.view()

  @doc false
  @spec report_public_state(GenServer.server()) :: :ok | {:error, term()}
  def report_public_state(server \\ __MODULE__) do
    case Diagnostics.transition(server, :public_state_requested) do
      {:ok, _state} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_step(:idle, event, command, payload)
       when event in [:begin_tailnet_change, :begin_cluster_change] do
    phase = command.scope
    state = phase_state(phase)

    case start_change(payload, command, phase) do
      {:ok, payload} -> finish(:idle, event, state, payload)
      {:error, payload} -> finish(:idle, event, :idle, payload)
    end
  end

  defp execute_step(:idle, :stage_internet, command, payload) do
    id = change_id()
    timeout = if payload.current["configured"], do: command.timeout, else: nil

    with {:ok, candidate} <- Settings.build_internet(payload.current, command.params),
         :ok <- Persistence.write_candidate(candidate, payload.root) do
      case payload.ops.internet.(Settings.internet(candidate)) do
        {:ok, _checks} ->
          pending = %{
            id: id,
            phase: :tailnet,
            source_connection: command.source_connection,
            timeout: timeout,
            deadline: deadline(timeout),
            scope: :complete,
            candidate: candidate
          }

          payload =
            payload
            |> Map.merge(%{pending: pending, last_error: nil})
            |> put_result(command.id, {:ok, Context.public_pending(pending)})
            |> refresh_diagnostics()
            |> notify()

          finish(:idle, :stage_internet, :needs_tailnet, payload)

        {:error, reason} ->
          payload = rollback_candidate(payload, candidate, reason)
          finish(:idle, :stage_internet, :idle, put_result(payload, command.id, {:error, reason}))
      end
    else
      {:error, reason} ->
        finish(:idle, :stage_internet, :idle, put_result(payload, command.id, {:error, reason}))
    end
  end

  defp execute_step(state, :update_internet, command, payload) do
    case payload.pending do
      %{id: id, scope: :complete} = pending when id == command.change_id ->
        update_internet_candidate(state, command, payload, pending)

      %{id: id} when id == command.change_id ->
        finish(state, :update_internet, state, outside_scope(payload, command.id))

      _missing ->
        finish(state, :update_internet, state, not_found(payload, command.id))
    end
  end

  defp execute_step(state, :stage_tailnet, command, payload) do
    case payload.pending do
      %{id: id, scope: scope} = pending
      when id == command.change_id and scope in [:complete, :tailnet] ->
        stage_tailnet_candidate(state, command, payload, pending)

      %{id: id} when id == command.change_id ->
        finish(state, :stage_tailnet, state, outside_scope(payload, command.id))

      _missing ->
        finish(state, :stage_tailnet, state, not_found(payload, command.id))
    end
  end

  defp execute_step(state, :stage_cluster, command, payload) do
    group = command.params |> get_in(["cluster", "group"]) |> blank_nil()

    with %{id: id, scope: scope} = pending
         when id == command.change_id and scope in [:complete, :cluster] <- payload.pending,
         {:ok, group} <- Cluster.validate_group(group) do
      candidate =
        pending.candidate
        |> Map.put("configured", true)
        |> Map.put("cluster", %{"group" => group})
        |> Settings.touch()

      with :ok <- payload.ops.cluster.(group),
           :ok <- Persistence.write_candidate(candidate, payload.root) do
        pending = advance(pending, :confirmation, candidate)

        payload =
          payload
          |> Map.merge(%{pending: pending, last_error: nil})
          |> put_result(command.id, {:ok, Context.public_pending(pending)})
          |> refresh_diagnostics()
          |> notify()

        finish(state, :stage_cluster, :needs_confirmation, payload)
      else
        {:error, reason} ->
          payload.ops.cluster.(Settings.cluster_group(pending.candidate))
          finish(state, :stage_cluster, state, put_result(payload, command.id, {:error, reason}))
      end
    else
      %{id: id} when id == command.change_id ->
        finish(state, :stage_cluster, state, outside_scope(payload, command.id))

      nil ->
        finish(state, :stage_cluster, state, not_found(payload, command.id))

      %{} ->
        finish(state, :stage_cluster, state, not_found(payload, command.id))

      {:error, reason} ->
        finish(state, :stage_cluster, state, put_result(payload, command.id, {:error, reason}))
    end
  end

  defp execute_step(:needs_confirmation, :confirm, command, payload) do
    pending = payload.pending

    cond do
      pending.id != command.change_id ->
        finish(:needs_confirmation, :confirm, :needs_confirmation, not_found(payload, command.id))

      command.connection.tailnet? != true ->
        error = {:error, :tailnet_connection_required}

        finish(
          :needs_confirmation,
          :confirm,
          :needs_confirmation,
          put_result(payload, command.id, error)
        )

      pending.source_connection == command.connection.id ->
        error = {:error, :fresh_connection_required}

        finish(
          :needs_confirmation,
          :confirm,
          :needs_confirmation,
          put_result(payload, command.id, error)
        )

      true ->
        confirm_candidate(command, payload)
    end
  end

  defp execute_step(state, :revert, command, payload) do
    if payload.pending.id == command.change_id do
      payload =
        rollback_candidate(
          payload,
          payload.pending.candidate,
          :reverted,
          payload.pending.scope
        )

      result =
        if match?({:rollback_failed, _}, payload.last_error),
          do: {:error, payload.last_error},
          else: :ok

      finish(state, :revert, :idle, put_result(payload, command.id, result))
    else
      finish(state, :revert, state, not_found(payload, command.id))
    end
  end

  defp execute_step(state, :tick, _command, payload) do
    payload =
      rollback_candidate(
        payload,
        payload.pending.candidate,
        :revert_timeout,
        payload.pending.scope
      )

    finish(state, :tick, :idle, payload)
  end

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, payload) do
    finish(:*, :boot, :activating, refresh_diagnostics(payload))
  end

  def on_transition(
        :activating,
        :activation_completed,
        {ref, outcome},
        %{startup_effect: %{ref: ref}} = payload
      ) do
    payload = complete_activation(outcome, payload)
    finish(:activating, :activation_completed, :idle, payload)
  end

  def on_transition(:activating, :activation_completed, _stale, _payload),
    do: {:error, :stale_effect_completion}

  def on_transition(state, event, command, payload)
      when event in [
             :begin_tailnet_change,
             :begin_cluster_change,
             :stage_internet,
             :update_internet,
             :stage_tailnet,
             :stage_cluster,
             :confirm,
             :revert
           ] do
    step_effect = %{ref: make_ref(), from: state, event: event, command: command}
    finish(state, event, :executing_change, %{payload | step_effect: step_effect})
  end

  def on_transition(
        :executing_change,
        :configuration_step_completed,
        {ref, outcome},
        %{step_effect: %{ref: ref}} = payload
      ) do
    complete_configuration_step(outcome, payload)
  end

  def on_transition(:executing_change, :configuration_step_completed, _stale, _payload),
    do: {:error, :stale_effect_completion}

  def on_transition(:idle, :resume_runtime_change, _event, payload),
    do: finish(:idle, :resume_runtime_change, :awaiting_runtime_change, payload)

  def on_transition(:awaiting_runtime_change, :resume_runtime_change, _event, payload) do
    runtime_change = %{payload.runtime_change | dispatched: true}

    finish(
      :awaiting_runtime_change,
      :resume_runtime_change,
      :awaiting_runtime_change,
      %{payload | runtime_change: runtime_change}
    )
  end

  def on_transition(:activating, :runtime_state_changed, _event, payload),
    do: finish(:activating, :runtime_state_changed, :activating, payload)

  def on_transition(:idle, :runtime_state_changed, _event, payload),
    do: finish(:idle, :runtime_state_changed, :idle, payload)

  def on_transition(:idle, :configure_subnet_router, command, payload),
    do: begin_runtime_change(:subnet_router, command, payload)

  def on_transition(:idle, :configure_ssh, command, payload),
    do: begin_runtime_change(:ssh, command, payload)

  def on_transition(
        :persisting_runtime_change,
        :runtime_change_persistence_completed,
        event,
        payload
      ),
      do: persisted_runtime_change(event, payload)

  def on_transition(
        :finalizing_runtime_change,
        :runtime_change_persistence_completed,
        event,
        payload
      ),
      do: finalized_runtime_change(event, payload)

  def on_transition(:awaiting_runtime_change, :runtime_command_finished, event, payload),
    do: runtime_command_finished(event, payload)

  def on_transition(:finalizing_runtime_change, :runtime_command_finished, _event, payload),
    do:
      finish(
        :finalizing_runtime_change,
        :runtime_command_finished,
        :finalizing_runtime_change,
        payload
      )

  def on_transition(:awaiting_runtime_change, :runtime_state_changed, event, payload),
    do: runtime_state_evidence(event, payload)

  def on_transition(:idle, :heal, command, payload) do
    case pending_runtime_change(payload.current) do
      nil ->
        finish(:idle, :heal, :idle, put_result(payload, command.id, :ok))

      runtime_change ->
        runtime_change = %{runtime_change | command_id: command.id}

        finish(:idle, :heal, :awaiting_runtime_change, %{payload | runtime_change: runtime_change})
    end
  end

  def on_transition(state, :heal, command, payload),
    do: finish(state, :heal, state, put_result(payload, command.id, :ok))

  def on_transition(state, :public_state_requested, _event_payload, payload),
    do: finish(state, :public_state_requested, state, payload)

  def on_transition(:activating, :tick, _event_payload, payload),
    do: finish(:activating, :tick, :activating, payload)

  def on_transition(:idle, :tick, _event_payload, payload),
    do: finish(:idle, :tick, :idle, payload)

  def on_transition(state, :tick, _event_payload, payload)
      when state in [
             :persisting_runtime_change,
             :awaiting_runtime_change,
             :finalizing_runtime_change,
             :executing_change
           ],
      do: finish(state, :tick, state, payload)

  def on_transition(state, :tick, _event_payload, payload) do
    if expired?(payload.pending) do
      step_effect = %{ref: make_ref(), from: state, event: :tick, command: nil}
      finish(state, :tick, :executing_change, %{payload | step_effect: step_effect})
    else
      finish(state, :tick, state, refresh_diagnostics(payload))
    end
  end

  @impl Finitomata
  def on_timer(_state, %Finitomata.State{payload: payload}),
    do: {:transition, :tick, payload}

  @doc false
  def after_transition(state, payload) do
    payload.publisher.(Context.public(payload))
    after_committed(state, payload)
  end

  defp after_committed(:activating, payload) do
    ref = payload.startup_effect.ref

    case Effect.start(
           self(),
           ref,
           fn -> run_startup(payload) end,
           fn ref, outcome -> {:activation_completed, {ref, outcome}} end,
           timeout: payload.startup_timeout
         ) do
      {:ok, _coordinator} -> :ok
      {:error, reason} -> raise "Configuration activation launch failed: #{inspect(reason)}"
    end
  end

  defp after_committed(:executing_change, %{step_effect: step} = payload) do
    execution_payload = %{payload | step_effect: nil}

    case Effect.start(
           self(),
           step.ref,
           fn -> execute_step(step.from, step.event, step.command, execution_payload) end,
           fn ref, outcome -> {:configuration_step_completed, {ref, outcome}} end,
           timeout: payload.step_timeout
         ) do
      {:ok, _coordinator} -> :ok
      {:error, reason} -> raise "Configuration step launch failed: #{inspect(reason)}"
    end
  end

  defp after_committed(
         state,
         %{runtime_change: %{effect: %{ref: ref}} = change} = payload
       )
       when state in [:persisting_runtime_change, :finalizing_runtime_change] do
    settings = change.settings
    slot = payload.firmware.active
    root = payload.root

    case Effect.start(
           self(),
           ref,
           fn -> Persistence.write_slot(settings, slot, root) end,
           fn ref, outcome -> {:runtime_change_persistence_completed, {ref, outcome}} end,
           timeout: payload.effect_timeout
         ) do
      {:ok, _coordinator} -> :ok
      {:error, reason} -> raise "Configuration persistence launch failed: #{inspect(reason)}"
    end
  end

  defp after_committed(:idle, %{runtime_change: %{phase: :awaiting}}) do
    GenServer.cast(self(), {:resume_runtime_change, nil})
  end

  defp after_committed(
         :awaiting_runtime_change,
         %{runtime_change: %{dispatched: false} = change} = payload
       ) do
    result = dispatch_runtime_change(payload.ops, change)
    GenServer.cast(self(), {:runtime_command_finished, %{id: change.id, result: result}})
  end

  defp after_committed(_state, _payload), do: :ok

  defp confirm_candidate(command, payload) do
    case Persistence.promote_candidate(payload.firmware.active, payload.root) do
      :ok ->
        candidate = payload.pending.candidate

        {cleanup_result, subnet_result} = confirm_effects(payload, candidate)

        payload =
          payload
          |> Map.merge(%{
            current: candidate,
            pending: nil,
            last_error: post_confirmation_error(cleanup_result, subnet_result)
          })
          |> put_result(command.id, :ok)
          |> configure_access()
          |> refresh_diagnostics()
          |> notify()

        finish(:needs_confirmation, :confirm, :idle, payload)

      {:error, reason} ->
        error = {:error, {:settings_promotion_failed, reason}}

        finish(
          :needs_confirmation,
          :confirm,
          :needs_confirmation,
          put_result(payload, command.id, error)
        )
    end
  end

  defp confirm_effects(%{pending: %{scope: :tailnet}} = payload, candidate) do
    cleanup = payload.ops.commit_tailnet.(Context.tailnet_metadata(payload.current, candidate))
    {cleanup, :ok}
  end

  defp confirm_effects(%{pending: %{scope: :cluster}}, _candidate), do: {:ok, :ok}

  defp confirm_effects(payload, candidate) do
    cleanup = payload.ops.commit_tailnet.(Context.tailnet_metadata(payload.current, candidate))
    {cleanup, restore_subnet_router(candidate, payload.ops)}
  end

  defp update_internet_candidate(state, command, payload, pending) do
    with {:ok, candidate} <- Settings.update_internet(pending.candidate, command.params),
         {:ok, _checks} <- payload.ops.internet.(Settings.internet(candidate)) do
      persist_internet_candidate(state, command, payload, pending, candidate)
    else
      {:error, reason} ->
        finish(state, :update_internet, state, put_result(payload, command.id, {:error, reason}))
    end
  end

  defp persist_internet_candidate(state, command, payload, pending, candidate) do
    case Persistence.write_candidate(candidate, payload.root) do
      :ok ->
        pending = advance(pending, pending.phase, candidate)

        payload =
          payload
          |> Map.merge(%{pending: pending, last_error: nil})
          |> put_result(command.id, {:ok, Context.public_pending(pending)})
          |> refresh_diagnostics()
          |> notify()

        finish(state, :update_internet, state, payload)

      {:error, reason} ->
        payload.ops.internet_restore.(Settings.internet(pending.candidate))
        error = {:candidate_write_failed, reason}
        finish(state, :update_internet, state, put_result(payload, command.id, {:error, error}))
    end
  end

  defp start_change(%{current: %{"configured" => false}} = payload, command, _phase),
    do: {:error, put_result(payload, command.id, {:error, :gateway_not_configured})}

  defp start_change(payload, command, phase) do
    candidate = payload.current

    case Persistence.write_candidate(candidate, payload.root) do
      :ok ->
        pending = %{
          id: change_id(),
          phase: phase,
          scope: command.scope,
          source_connection: command.source_connection,
          timeout: command.timeout,
          deadline: deadline(command.timeout),
          candidate: candidate
        }

        payload =
          payload
          |> Map.merge(%{pending: pending, last_error: nil})
          |> put_result(command.id, {:ok, Context.public_pending(pending)})
          |> refresh_diagnostics()
          |> notify()

        {:ok, payload}

      {:error, reason} ->
        {:error, put_result(payload, command.id, {:error, reason})}
    end
  end

  defp stage_tailnet_candidate(state, command, payload, pending) do
    auth_token = command.params |> Map.get("auth_token") |> blank_nil()

    with :ok <- Settings.validate_auth_token(auth_token, pending.candidate),
         {:ok, candidate} <- apply_tailnet(payload, pending.candidate, auth_token, pending.id) do
      persist_tailnet_candidate(state, command, payload, pending, candidate)
    else
      {:error, reason} ->
        finish(state, :stage_tailnet, state, put_result(payload, command.id, {:error, reason}))
    end
  end

  defp persist_tailnet_candidate(state, command, payload, pending, candidate) do
    case Persistence.write_candidate(candidate, payload.root) do
      :ok ->
        cleanup_result = cleanup_replaced_tailnet(payload, pending.candidate, candidate)

        next_phase =
          case {pending.phase, pending.scope} do
            {:tailnet, :complete} -> :cluster
            {:tailnet, :tailnet} -> :confirmation
            {phase, _scope} -> phase
          end

        pending = advance(pending, next_phase, candidate)

        payload =
          payload
          |> Map.merge(%{pending: pending, last_error: cleanup_error(cleanup_result)})
          |> put_result(command.id, {:ok, Context.public_pending(pending)})
          |> refresh_diagnostics()
          |> notify()

        finish(state, :stage_tailnet, phase_state(next_phase), payload)

      {:error, reason} ->
        payload.ops.rollback_tailnet.(Context.tailnet_metadata(pending.candidate, candidate))
        error = {:candidate_write_failed, reason}
        finish(state, :stage_tailnet, state, put_result(payload, command.id, {:error, error}))
    end
  end

  defp begin_runtime_change(kind, command, %{current: %{"configured" => false}} = payload) do
    finish(
      :idle,
      runtime_change_event(kind),
      :idle,
      put_result(payload, command.id, {:error, :gateway_not_configured})
    )
  end

  defp begin_runtime_change(:subnet_router, command, payload) do
    routes = if command.enabled, do: command.routes, else: Settings.subnet_routes(payload.current)

    with {:ok, requested} <-
           Settings.validate_subnet_router(%{"enabled" => command.enabled, "routes" => routes}),
         :ok <- Settings.require_enabled_routes(requested) do
      start_runtime_change(:subnet_router, requested, command.id, payload)
    else
      {:error, reason} ->
        finish(
          :idle,
          :configure_subnet_router,
          :idle,
          put_result(payload, command.id, {:error, reason})
        )
    end
  end

  defp begin_runtime_change(:ssh, command, payload),
    do: start_runtime_change(:ssh, command.enabled, command.id, payload)

  defp start_runtime_change(kind, desired, command_id, payload) do
    id = change_id()

    updated =
      payload.current
      |> Settings.bump(runtime_setting(kind, desired))
      |> Settings.put_resource_change(kind, id, :pending)

    runtime_change = %{
      id: id,
      kind: kind,
      command_id: command_id,
      desired: desired,
      settings: updated,
      outcome: nil,
      phase: :persisting,
      dispatched: false,
      effect: %{ref: make_ref()}
    }

    finish(
      :idle,
      runtime_change_event(kind),
      :persisting_runtime_change,
      %{payload | runtime_change: runtime_change}
    )
  end

  defp persisted_runtime_change(
         {ref, outcome},
         %{runtime_change: %{effect: %{ref: ref}} = change} = payload
       ) do
    case persistence_result(outcome) do
      :ok ->
        change = %{change | phase: :awaiting, effect: nil}

        payload =
          payload
          |> Map.merge(%{
            current: change.settings,
            runtime_change: change,
            last_error: nil
          })
          |> refresh_diagnostics()

        finish(
          :persisting_runtime_change,
          :runtime_change_persistence_completed,
          :awaiting_runtime_change,
          payload
        )

      {:error, reason} ->
        error = {:settings_write_failed, reason}

        payload =
          payload
          |> Map.merge(%{runtime_change: nil, last_error: error})
          |> put_result(change.command_id, {:error, error})

        finish(
          :persisting_runtime_change,
          :runtime_change_persistence_completed,
          :idle,
          payload
        )
    end
  end

  defp persisted_runtime_change({_ref, _outcome}, _payload),
    do: {:error, :stale_runtime_change_completion}

  defp runtime_command_finished(
         %{id: id, result: result},
         %{runtime_change: %{id: id} = change} = payload
       ) do
    case result do
      :ok ->
        await_runtime_evidence(payload, change)

      {:ok, _value} ->
        await_runtime_evidence(payload, change)

      {:error, reason} ->
        begin_runtime_finalization(
          payload,
          :failed,
          {:owner_command_failed, reason},
          :runtime_command_finished
        )

      invalid ->
        begin_runtime_finalization(
          payload,
          :failed,
          {:invalid_owner_command_result, invalid},
          :runtime_command_finished
        )
    end
  end

  defp runtime_command_finished(_stale, payload),
    do:
      finish(
        :awaiting_runtime_change,
        :runtime_command_finished,
        :awaiting_runtime_change,
        payload
      )

  defp await_runtime_evidence(payload, change) do
    change = %{change | dispatched: true}

    finish(
      :awaiting_runtime_change,
      :runtime_command_finished,
      :awaiting_runtime_change,
      %{payload | runtime_change: change}
    )
  end

  defp runtime_state_evidence(
         %{source: kind, status: status},
         %{runtime_change: %{kind: kind, id: id}} = payload
       ) do
    cond do
      Map.get(status, :applied_change_id) == id ->
        begin_runtime_finalization(payload, :applied, nil, :runtime_state_changed)

      Map.get(status, :failed_change_id) == id ->
        begin_runtime_finalization(
          payload,
          :failed,
          :owner_reported_failure,
          :runtime_state_changed
        )

      true ->
        finish(
          :awaiting_runtime_change,
          :runtime_state_changed,
          :awaiting_runtime_change,
          payload
        )
    end
  end

  defp runtime_state_evidence(_unrelated, payload),
    do:
      finish(
        :awaiting_runtime_change,
        :runtime_state_changed,
        :awaiting_runtime_change,
        payload
      )

  defp begin_runtime_finalization(payload, outcome, reason, event) do
    change = payload.runtime_change

    settings =
      Settings.put_resource_change(
        payload.current,
        change.kind,
        change.id,
        outcome
      )

    change = %{
      change
      | settings: settings,
        outcome: outcome,
        phase: :finalizing,
        effect: %{ref: make_ref()}
    }

    payload = %{
      payload
      | runtime_change: change,
        last_error: if(outcome == :failed, do: {:runtime_change_failed, reason})
    }

    finish(
      :awaiting_runtime_change,
      event,
      :finalizing_runtime_change,
      payload
    )
  end

  defp finalized_runtime_change(
         {ref, outcome},
         %{runtime_change: %{effect: %{ref: ref}} = change} = payload
       ) do
    case persistence_result(outcome) do
      :ok ->
        result = runtime_change_result(change)

        payload =
          payload
          |> Map.merge(%{current: change.settings, runtime_change: nil})
          |> put_result(change.command_id, result)
          |> refresh_diagnostics()

        finish(
          :finalizing_runtime_change,
          :runtime_change_persistence_completed,
          :idle,
          payload
        )

      {:error, reason} ->
        error = {:settings_write_failed, reason}

        payload =
          payload
          |> Map.merge(%{runtime_change: nil, last_error: error})
          |> put_result(change.command_id, {:error, error})

        finish(
          :finalizing_runtime_change,
          :runtime_change_persistence_completed,
          :idle,
          payload
        )
    end
  end

  defp finalized_runtime_change({_ref, _outcome}, _payload),
    do: {:error, :stale_runtime_change_completion}

  defp runtime_change_result(%{outcome: :applied, kind: :ssh}), do: :ok

  defp runtime_change_result(%{outcome: :applied, kind: :subnet_router, settings: settings}),
    do: {:ok, Settings.public(settings).subnet_router}

  defp runtime_change_result(%{outcome: :failed}),
    do: {:error, :runtime_change_failed}

  defp persistence_result({:returned, :ok}), do: :ok
  defp persistence_result({:returned, {:error, reason}}), do: {:error, reason}
  defp persistence_result(:timed_out), do: {:error, :persistence_timeout}
  defp persistence_result(:cancelled), do: {:error, :persistence_cancelled}
  defp persistence_result({:crashed, _kind, _reason, _stack}), do: {:error, :persistence_crashed}
  defp persistence_result(_invalid), do: {:error, :invalid_persistence_result}

  defp runtime_setting(:ssh, enabled), do: %{"ssh_enabled" => enabled}
  defp runtime_setting(:subnet_router, requested), do: %{"subnet_router" => requested}
  defp runtime_change_event(:ssh), do: :configure_ssh
  defp runtime_change_event(:subnet_router), do: :configure_subnet_router

  defp pending_runtime_change(settings) do
    case Settings.pending_resource_change(settings) do
      {:ssh, id} ->
        recovered_runtime_change(:ssh, id, Settings.ssh_enabled(settings), settings)

      {:subnet_router, id} ->
        recovered_runtime_change(:subnet_router, id, Settings.subnet_router(settings), settings)

      nil ->
        nil
    end
  end

  defp recovered_runtime_change(kind, id, desired, settings) do
    %{
      id: id,
      kind: kind,
      command_id: nil,
      desired: desired,
      settings: settings,
      outcome: nil,
      phase: :awaiting,
      dispatched: false,
      effect: nil
    }
  end

  defp dispatch_runtime_change(ops, %{kind: :ssh, desired: enabled, id: id}),
    do: invoke_ssh(ops, enabled, id)

  defp dispatch_runtime_change(ops, %{kind: :subnet_router, desired: requested, id: id}),
    do: invoke_subnet_router(ops, requested["enabled"], requested["routes"], id)

  defp invoke_ssh(ops, enabled, id) do
    if is_function(ops.ssh, 2), do: ops.ssh.(enabled, id), else: ops.ssh.(enabled)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp invoke_subnet_router(ops, enabled, routes, id) do
    if is_function(ops.subnet_router, 3),
      do: ops.subnet_router.(enabled, routes, id),
      else: ops.subnet_router.(enabled, routes)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp command(server, event, payload, timeout \\ 45_000),
    do: Diagnostics.command(server, event, payload, timeout)

  defp complete_configuration_step(
         {:returned, {:ok, to, completed_payload}},
         _payload
       ) do
    completed_payload = %{completed_payload | step_effect: nil}

    finish(
      :executing_change,
      :configuration_step_completed,
      to,
      completed_payload
    )
  end

  defp complete_configuration_step(:timed_out, payload),
    do: configuration_step_failed(payload, :configuration_step_timed_out)

  defp complete_configuration_step(:cancelled, payload),
    do: configuration_step_failed(payload, :configuration_step_cancelled)

  defp complete_configuration_step({:crashed, _kind, _reason, _stack}, payload),
    do: configuration_step_failed(payload, :configuration_step_crashed)

  defp complete_configuration_step(_invalid, payload),
    do: configuration_step_failed(payload, :invalid_configuration_step_result)

  defp configuration_step_failed(payload, reason) do
    step = payload.step_effect
    payload = %{payload | step_effect: nil, last_error: reason}

    payload =
      case step.command do
        %{id: id} -> put_result(payload, id, {:error, reason})
        _timer -> payload
      end

    finish(
      :executing_change,
      :configuration_step_completed,
      step.from,
      payload,
      reason: reason,
      error: reason
    )
  end

  defp run_startup(payload) do
    activated =
      payload
      |> recover_candidate()
      |> activate_current()
      |> configure_access()

    %{
      recovered_candidate: activated.recovered_candidate,
      last_error: activated.last_error
    }
  end

  defp complete_activation({:returned, result}, payload) when is_map(result) do
    payload
    |> Map.merge(%{
      recovered_candidate: result.recovered_candidate,
      last_error: result.last_error,
      startup_effect: nil
    })
    |> refresh_diagnostics()
  end

  defp complete_activation(:timed_out, payload),
    do: startup_failed(payload, :activation_timed_out)

  defp complete_activation(:cancelled, payload),
    do: startup_failed(payload, :activation_cancelled)

  defp complete_activation({:crashed, _kind, _reason, _stack}, payload),
    do: startup_failed(payload, :activation_crashed)

  defp complete_activation(_invalid, payload),
    do: startup_failed(payload, :invalid_activation_result)

  defp startup_failed(payload, reason) do
    payload
    |> Map.merge(%{last_error: reason, startup_effect: nil})
    |> refresh_diagnostics()
  end

  defp recover_candidate(%{recovered_candidate: nil} = payload), do: payload

  defp recover_candidate(payload) do
    result = restore_runtime(payload.current, payload.recovered_candidate, payload.ops, :complete)
    clear_result = Persistence.clear_candidate(payload.root)

    last_error =
      case {result, clear_result} do
        {:ok, :ok} -> :recovered_unconfirmed_configuration
        {{:error, failures}, _clear} -> {:rollback_failed, failures}
        {:ok, {:error, reason}} -> {:candidate_cleanup_failed, reason}
      end

    %{payload | recovered_candidate: nil, last_error: last_error}
  end

  defp activate_current(payload) do
    current = payload.current

    results = [
      internet: payload.ops.internet_restore.(Settings.internet(current)),
      tailnet: payload.ops.tailnet_restore.(Settings.tailnet_profile(current)),
      subnet_router: restore_subnet_router(current, payload.ops),
      ssh: invoke_ssh(payload.ops, Settings.ssh_enabled(current), nil),
      cluster: payload.ops.cluster.(Settings.cluster_group(current))
    ]

    failures = Enum.reject(results, fn {_layer, result} -> result == :ok end)
    if failures == [], do: payload, else: %{payload | last_error: {:activation_failed, failures}}
  end

  defp rollback_candidate(payload, candidate, reason, scope \\ :complete) do
    rollback_result = restore_runtime(payload.current, candidate, payload.ops, scope)
    clear_result = Persistence.clear_candidate(payload.root)

    last_error =
      case {rollback_result, clear_result} do
        {:ok, :ok} -> reason
        {{:error, failures}, _clear} -> {:rollback_failed, failures}
        {:ok, {:error, clear_reason}} -> {:candidate_cleanup_failed, clear_reason}
      end

    payload
    |> Map.merge(%{pending: nil, last_error: last_error})
    |> configure_access()
    |> refresh_diagnostics()
    |> notify()
  end

  defp restore_runtime(current, candidate, ops, :tailnet) do
    ops.rollback_tailnet.(Context.tailnet_metadata(current, candidate))
  end

  defp restore_runtime(current, _candidate, ops, :cluster) do
    ops.cluster.(Settings.cluster_group(current))
  end

  defp restore_runtime(current, candidate, ops, :complete) do
    results = [
      internet: ops.internet_restore.(Settings.internet(current)),
      tailnet: ops.rollback_tailnet.(Context.tailnet_metadata(current, candidate)),
      subnet_router: restore_subnet_router(current, ops),
      ssh: invoke_ssh(ops, Settings.ssh_enabled(current), nil),
      cluster: ops.cluster.(Settings.cluster_group(current))
    ]

    failures = Enum.reject(results, fn {_layer, result} -> result in [:ok, {:ok, nil}] end)
    if failures == [], do: :ok, else: {:error, failures}
  end

  defp restore_subnet_router(%{"configured" => false}, _ops), do: :ok

  defp restore_subnet_router(settings, ops) do
    desired = Settings.subnet_router(settings)

    case invoke_subnet_router(ops, desired["enabled"], desired["routes"], nil) do
      {:ok, _routes} -> :ok
      {:error, _reason} = error -> error
      invalid -> {:error, {:invalid_subnet_router_result, invalid}}
    end
  end

  defp apply_tailnet(_payload, candidate, nil, _id) do
    case Settings.tailnet_profile(candidate) do
      profile_id when is_binary(profile_id) -> {:ok, candidate}
      nil -> {:error, :tailscale_auth_key_required}
    end
  end

  defp apply_tailnet(payload, candidate, auth_token, id) do
    previous_profile_id = Settings.tailnet_profile(candidate)

    case payload.ops.stage_tailnet.(auth_token, id, previous_profile_id) do
      {:ok, %{"candidate_profile_id" => candidate_profile_id}}
      when is_binary(candidate_profile_id) ->
        candidate = put_in(candidate, ["tailnet", "profile_id"], candidate_profile_id)
        {:ok, Settings.touch(candidate)}

      {:error, reason, metadata} ->
        payload.ops.rollback_tailnet.(metadata)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, :tailnet_candidate_unavailable}
    end
  end

  defp cleanup_replaced_tailnet(payload, previous_candidate, candidate) do
    if Settings.tailnet_profile(previous_candidate) == Settings.tailnet_profile(payload.current) do
      :ok
    else
      payload.ops.commit_tailnet.(Context.tailnet_metadata(previous_candidate, candidate))
    end
  end

  defp configure_access(payload) do
    cond do
      not payload.current["configured"] ->
        payload.ops.access.(:commissioning, Context.active_interface(payload.current))

      payload.keep_local_access ->
        payload.ops.access.(:commissioning, Context.active_interface(payload.current))

      true ->
        payload.ops.disable_access.()
    end

    payload
  end

  defp advance(pending, phase, candidate) do
    %{pending | phase: phase, candidate: candidate, deadline: deadline(pending.timeout)}
  end

  defp deadline(nil), do: nil
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp expired?(%{deadline: nil}), do: false
  defp expired?(%{deadline: deadline}), do: System.monotonic_time(:millisecond) >= deadline

  defp phase_state(:tailnet), do: :needs_tailnet
  defp phase_state(:cluster), do: :needs_cluster
  defp phase_state(:confirmation), do: :needs_confirmation

  defp refresh_diagnostics(payload) do
    %{payload | desired: Settings.public(payload.current), observed: Context.public(payload)}
  end

  defp notify(payload), do: payload

  defp outside_scope(payload, id),
    do: put_result(payload, id, {:error, :configuration_change_outside_scope})

  defp not_found(payload, id),
    do: put_result(payload, id, {:error, :configuration_change_not_found})

  defp put_result(payload, id, result), do: %{payload | last_result: {id, result}}

  defp finish(from, event, to, payload, options \\ []) do
    {:ok, to, Diagnostics.record(payload, from, event, to, options)}
  end

  defp cleanup_error(:ok), do: nil
  defp cleanup_error({:error, reason}), do: {:tailnet_profile_cleanup_failed, reason}

  defp post_confirmation_error(cleanup_result, subnet_result) do
    cleanup_error(cleanup_result) ||
      runtime_error(:subnet_router_activation_failed, subnet_result)
  end

  defp runtime_error(_type, :ok), do: nil
  defp runtime_error(type, {:error, reason}), do: {type, reason}

  defp publish_configuration(configuration) do
    case NervesGate.DeviceState.publish({:state_reported, :configuration, configuration}) do
      :ok -> :ok
      {:error, :shutting_down} -> :ok
      {:error, reason} -> raise "Configuration DeviceState publication failed: #{inspect(reason)}"
    end
  end

  defp blank_nil(nil), do: nil
  defp blank_nil(value) when is_binary(value), do: value |> String.trim() |> empty_nil()
  defp empty_nil(""), do: nil
  defp empty_nil(value), do: value

  defp change_id do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp firmware_metadata do
    %{active: active} = Nerves.Runtime.firmware_slots()

    slots =
      Map.new(@slots, fn slot ->
        {slot,
         %{
           "uuid" => Nerves.Runtime.KV.get("#{slot}.nerves_fw_uuid") || "unknown",
           "version" => Nerves.Runtime.KV.get("#{slot}.nerves_fw_version") || "unknown"
         }}
      end)

    %{active: active, slots: slots}
  end
end

defmodule NervesGate.Gateway.Configuration.Context do
  @moduledoc "Pure public projections and timing helpers for staged gateway configuration."

  alias NervesGate.Gateway.Settings
  alias NervesGate.Internet.Config

  @spec public(map()) :: map()
  def public(payload) do
    %{
      configured: payload.current["configured"],
      current: Settings.public(payload.current),
      pending: if(payload.pending, do: public_pending(payload.pending)),
      last_error: public_error(payload.last_error)
    }
  end

  @spec public_pending(map()) :: map()
  def public_pending(pending) do
    %{
      id: pending.id,
      phase: pending.phase,
      scope: Map.get(pending, :scope, :complete),
      candidate: Settings.public(pending.candidate),
      remaining_seconds: remaining_seconds(pending.deadline)
    }
  end

  defp public_error(nil), do: nil
  defp public_error(reason) when is_atom(reason), do: reason
  defp public_error({reason, _private}) when is_atom(reason), do: reason
  defp public_error(_private), do: :configuration_failed

  @spec remaining_seconds(integer() | nil) :: non_neg_integer() | nil
  def remaining_seconds(nil), do: nil

  def remaining_seconds(deadline) do
    max(0, div(deadline - System.monotonic_time(:millisecond) + 999, 1_000))
  end

  @spec active_interface(map()) :: String.t() | nil
  def active_interface(settings) do
    case Settings.internet(settings) do
      %Config{interface: interface} -> interface
      nil -> nil
    end
  end

  @spec tailnet_metadata(map(), map()) :: map()
  def tailnet_metadata(current, candidate) do
    %{
      "previous_profile_id" => Settings.tailnet_profile(current),
      "candidate_profile_id" => Settings.tailnet_profile(candidate)
    }
  end
end

defmodule NervesGate.Gateway.Runtime do
  @moduledoc "Explicit owner-command boundaries used by the configuration workflow."

  alias NervesGate.Cluster, as: Cluster
  alias NervesGate.Commissioning, as: Commissioning
  alias NervesGate.Internet, as: Internet
  alias NervesGate.SSH, as: SSH
  alias NervesGate.SubnetRouter, as: SubnetRouter
  alias NervesGate.Tailnet.Enrollment

  @spec default() :: map()
  def default do
    %{
      internet: &Internet.configure/1,
      internet_restore: &Internet.restore/1,
      internet_observe: &Internet.poll_now/0,
      stage_tailnet: &Enrollment.stage/3,
      tailnet_restore: &Enrollment.select/1,
      commit_tailnet: &Enrollment.commit/1,
      rollback_tailnet: &Enrollment.rollback/1,
      subnet_router: fn enabled, routes, change_id ->
        SubnetRouter.configure(enabled, routes, SubnetRouter, change_id: change_id)
      end,
      ssh: fn enabled, change_id ->
        SSH.set_enabled(enabled, SSH, change_id: change_id)
      end,
      cluster: &Cluster.configure/1,
      access: &Commissioning.enable/2,
      disable_access: &Commissioning.disable/0
    }
  end
end
