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
  activating --> rolling_back : activation_completed
  activating --> activating : tick
  activating --> activating : public_state_requested
  idle --> executing_change : stage_internet
  idle --> executing_change : update_settings
  needs_tailnet --> executing_change : stage_tailnet
  needs_cluster --> executing_change : stage_cluster
  needs_confirmation --> executing_change : confirm
  needs_tailnet --> needs_tailnet : revert
  needs_tailnet --> rolling_back : revert
  needs_cluster --> needs_cluster : revert
  needs_cluster --> rolling_back : revert
  needs_confirmation --> needs_confirmation : revert
  needs_confirmation --> rolling_back : revert
  needs_tailnet --> needs_tailnet : tick
  needs_tailnet --> rolling_back : tick
  needs_cluster --> needs_cluster : tick
  needs_cluster --> rolling_back : tick
  needs_confirmation --> needs_confirmation : tick
  needs_confirmation --> rolling_back : tick
  executing_change --> idle : configuration_step_completed
  executing_change --> needs_tailnet : configuration_step_completed
  executing_change --> needs_cluster : configuration_step_completed
  executing_change --> needs_confirmation : configuration_step_completed
  executing_change --> rolling_back : configuration_step_completed
  executing_change --> executing_change : tick
  rolling_back --> idle : rollback_completed
  rolling_back --> rolling_back : rollback_completed
  rolling_back --> rolling_back : tick
  executing_change --> executing_change : public_state_requested
  idle --> persisting_runtime_change : configure_subnet_router
  idle --> persisting_runtime_change : configure_ssh
  idle --> idle : configure_subnet_router
  idle --> idle : configure_ssh
  persisting_runtime_change --> idle : runtime_change_persistence_completed
  persisting_runtime_change --> persisting_runtime_change : tick
  idle --> idle : tick
  idle --> idle : heal
  needs_tailnet --> needs_tailnet : heal
  needs_cluster --> needs_cluster : heal
  needs_confirmation --> needs_confirmation : heal
  idle --> idle : public_state_requested
  needs_tailnet --> needs_tailnet : public_state_requested
  needs_cluster --> needs_cluster : public_state_requested
  needs_confirmation --> needs_confirmation : public_state_requested
  persisting_runtime_change --> persisting_runtime_change : public_state_requested
  rolling_back --> rolling_back : public_state_requested
  activating --> [*] : terminate
  executing_change --> [*] : terminate
  rolling_back --> [*] : terminate
  idle --> [*] : terminate
  persisting_runtime_change --> [*] : terminate
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
      runtime_change: nil,
      startup_effect: %{ref: make_ref()},
      step_effect: nil,
      rollback_effect: nil,
      rollback_context: nil,
      ops: Map.merge(Runtime.default(), Map.new(Keyword.get(options, :ops, []))),
      keep_local_access:
        Keyword.get(
          options,
          :keep_local_access,
          Application.get_env(:nerves_gate, :local_dashboard, false)
        ),
      reply: nil,
      effect_timeout: Keyword.get(options, :effect_timeout, 30_000),
      startup_timeout: Keyword.get(options, :startup_timeout, 120_000),
      step_timeout: Keyword.get(options, :step_timeout, 180_000),
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

  @type settings_scope :: :internet | :tailnet | :cluster

  @spec update_settings(settings_scope(), map(), String.t(), pos_integer(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def update_settings(
        scope,
        params,
        source_connection,
        timeout \\ @default_timeout,
        server \\ __MODULE__
      )

  def update_settings(scope, params, source_connection, timeout, server)
      when scope in [:internet, :tailnet, :cluster] and is_integer(timeout) and timeout > 0 do
    command(server, :update_settings, %{
      scope: scope,
      params: params,
      source_connection: source_connection,
      timeout: timeout
    })
  end

  def update_settings(_scope, _params, _source_connection, _timeout, _server),
    do: {:error, :invalid_settings_update}

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

  @spec stage_tailnet(String.t(), map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def stage_tailnet(id, params, server \\ __MODULE__),
    do: command(server, :stage_tailnet, %{change_id: id, params: params}, 165_000)

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

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server \\ __MODULE__), do: server |> Diagnostics.state() |> Diagnostics.view()

  @doc false
  @spec busy?(GenServer.server()) :: boolean()
  def busy?(server \\ __MODULE__) do
    case Diagnostics.state(server) do
      %Finitomata.State{current: :idle} -> false
      %Finitomata.State{} -> true
      nil -> true
    end
  end

  @doc false
  @spec report_public_state(GenServer.server()) :: :ok | {:error, term()}
  def report_public_state(server \\ __MODULE__) do
    case Diagnostics.transition(server, :public_state_requested) do
      {:ok, _state} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp guarded_step(step, payload) do
    if payload.ops.firmware_busy.() do
      finish(
        step.from,
        step.event,
        step.from,
        put_result(payload, step.command.id, {:error, :firmware_update_in_progress})
      )
    else
      execute_step(step.from, step.event, step.command, payload)
    end
  end

  defp execute_step(:idle, :update_settings, command, payload) do
    update_configured_settings(command, payload)
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
          fail_candidate_application(
            :stage_internet,
            command,
            payload,
            candidate,
            reason,
            :complete
          )
      end
    else
      {:error, reason} ->
        finish(:idle, :stage_internet, :idle, put_result(payload, command.id, {:error, reason}))
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

    case payload.recovered_candidate do
      nil ->
        finish(:activating, :activation_completed, :idle, payload)

      candidate ->
        context = %{
          candidate: candidate,
          scope: :complete,
          reason: :recovered_unkept_configuration,
          reply_id: nil,
          attempt: 0,
          retry_at: nil
        }

        payload = %{
          payload
          | rollback_context: context,
            rollback_effect: %{ref: make_ref()}
        }

        finish(:activating, :activation_completed, :rolling_back, payload)
    end
  end

  def on_transition(:activating, :activation_completed, _stale, _payload),
    do: {:error, :stale_effect_completion}

  def on_transition(state, event, command, payload)
      when event in [
             :update_settings,
             :stage_internet,
             :stage_tailnet,
             :stage_cluster,
             :confirm
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

  def on_transition(state, :revert, command, payload)
      when state in [:needs_tailnet, :needs_cluster, :needs_confirmation] do
    if payload.pending.id == command.change_id do
      begin_rollback(state, :revert, command.id, :reverted, payload)
    else
      finish(state, :revert, state, not_found(payload, command.id))
    end
  end

  def on_transition(
        :rolling_back,
        :rollback_completed,
        {ref, outcome},
        %{rollback_effect: %{ref: ref}} = payload
      ) do
    complete_rollback(outcome, payload)
  end

  def on_transition(:rolling_back, :rollback_completed, _stale, _payload),
    do: {:error, :stale_rollback_completion}

  def on_transition(:idle, :configure_subnet_router, command, payload) do
    if payload.ops.firmware_busy.(),
      do:
        finish(
          :idle,
          :configure_subnet_router,
          :idle,
          put_result(payload, command.id, {:error, :firmware_update_in_progress})
        ),
      else: begin_runtime_change(:subnet_router, command, payload)
  end

  def on_transition(:idle, :configure_ssh, command, payload) do
    if payload.ops.firmware_busy.(),
      do:
        finish(
          :idle,
          :configure_ssh,
          :idle,
          put_result(payload, command.id, {:error, :firmware_update_in_progress})
        ),
      else: begin_runtime_change(:ssh, command, payload)
  end

  def on_transition(
        :persisting_runtime_change,
        :runtime_change_persistence_completed,
        event,
        payload
      ),
      do: persisted_runtime_change(event, payload)

  def on_transition(:idle, :heal, command, payload),
    do: finish(:idle, :heal, :idle, put_result(payload, command.id, :ok))

  def on_transition(state, :heal, command, payload),
    do: finish(state, :heal, state, put_result(payload, command.id, :ok))

  def on_transition(state, :public_state_requested, _event_payload, payload),
    do: finish(state, :public_state_requested, state, payload)

  def on_transition(:activating, :tick, _event_payload, payload),
    do: finish(:activating, :tick, :activating, payload)

  def on_transition(:idle, :tick, _event_payload, payload),
    do: finish(:idle, :tick, :idle, payload)

  def on_transition(state, :tick, _event_payload, payload)
      when state in [:persisting_runtime_change, :executing_change],
      do: finish(state, :tick, state, payload)

  def on_transition(:rolling_back, :tick, _event_payload, payload) do
    if is_nil(payload.rollback_effect) and retry_due?(payload.rollback_context) do
      effect = %{ref: make_ref()}
      finish(:rolling_back, :tick, :rolling_back, %{payload | rollback_effect: effect})
    else
      finish(:rolling_back, :tick, :rolling_back, payload)
    end
  end

  def on_transition(state, :tick, _event_payload, payload) do
    if expired?(payload.pending),
      do: begin_rollback(state, :tick, nil, :revert_timeout, payload),
      else: finish(state, :tick, state, refresh_diagnostics(payload))
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
           fn -> guarded_step(step, execution_payload) end,
           fn ref, outcome -> {:configuration_step_completed, {ref, outcome}} end,
           timeout: payload.step_timeout
         ) do
      {:ok, _coordinator} -> :ok
      {:error, reason} -> raise "Configuration step launch failed: #{inspect(reason)}"
    end
  end

  defp after_committed(
         :rolling_back,
         %{rollback_effect: %{ref: ref}} = payload
       ) do
    rollback_payload = %{payload | rollback_effect: nil}

    case Effect.start(
           self(),
           ref,
           fn -> run_rollback(rollback_payload) end,
           fn ref, outcome -> {:rollback_completed, {ref, outcome}} end,
           timeout: payload.step_timeout
         ) do
      {:ok, _coordinator} -> :ok
      {:error, reason} -> raise "Configuration rollback launch failed: #{inspect(reason)}"
    end
  end

  defp after_committed(
         :persisting_runtime_change,
         %{runtime_change: %{effect: %{ref: ref}} = change} = payload
       ) do
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

  defp confirm_effects(%{pending: %{scope: :internet}}, _candidate), do: {:ok, :ok}

  defp confirm_effects(%{pending: %{scope: :tailnet}} = payload, candidate) do
    cleanup = payload.ops.commit_tailnet.(Context.tailnet_metadata(payload.current, candidate))
    {cleanup, :ok}
  end

  defp confirm_effects(%{pending: %{scope: :cluster}}, _candidate), do: {:ok, :ok}

  defp confirm_effects(payload, candidate) do
    cleanup = payload.ops.commit_tailnet.(Context.tailnet_metadata(payload.current, candidate))
    {cleanup, restore_subnet_router(candidate, payload.ops)}
  end

  defp update_configured_settings(command, %{current: %{"configured" => false}} = payload) do
    finish(
      :idle,
      :update_settings,
      :idle,
      put_result(payload, command.id, {:error, :gateway_not_configured})
    )
  end

  defp update_configured_settings(%{scope: :internet} = command, payload) do
    id = change_id()

    with {:ok, candidate} <- Settings.build_internet(payload.current, command.params),
         :ok <- Persistence.write_candidate(candidate, payload.root) do
      case payload.ops.internet.(Settings.internet(candidate)) do
        {:ok, _checks} -> complete_settings_update(command, payload, id, candidate)
        {:error, reason} -> fail_settings_update(command, payload, candidate, reason)
      end
    else
      {:error, reason} ->
        Persistence.clear_candidate(payload.root)

        finish(
          :idle,
          :update_settings,
          :idle,
          put_result(payload, command.id, {:error, reason})
        )
    end
  end

  defp update_configured_settings(%{scope: :cluster} = command, payload) do
    group = command.params |> get_in(["cluster", "group"]) |> blank_nil()

    case Cluster.validate_group(group) do
      {:ok, group} -> apply_cluster_settings_update(command, payload, group)
      {:error, reason} -> reject_settings_update(command, payload, reason)
    end
  end

  defp update_configured_settings(%{scope: :tailnet} = command, payload) do
    id = change_id()
    auth_token = command.params |> Map.get("auth_token") |> blank_nil()

    with :ok <- Settings.validate_auth_token(auth_token, payload.current),
         :ok <- Persistence.write_candidate(payload.current, payload.root) do
      apply_tailnet_settings_update(command, payload, auth_token, id)
    else
      {:error, reason} ->
        Persistence.clear_candidate(payload.root)
        reject_settings_update(command, payload, reason)
    end
  end

  defp apply_cluster_settings_update(command, payload, group) do
    candidate = Settings.bump(payload.current, %{"cluster" => %{"group" => group}})

    with :ok <- Persistence.write_candidate(candidate, payload.root),
         :ok <- payload.ops.cluster.(group) do
      complete_settings_update(command, payload, change_id(), candidate)
    else
      {:error, reason} -> fail_settings_update(command, payload, candidate, reason)
    end
  end

  defp apply_tailnet_settings_update(command, payload, auth_token, id) do
    case apply_tailnet(payload, payload.current, auth_token, id) do
      {:ok, staged_candidate} ->
        persist_tailnet_settings_update(command, payload, id, staged_candidate)

      {:error, reason} ->
        fail_settings_update(command, payload, payload.current, reason)
    end
  end

  defp persist_tailnet_settings_update(command, payload, id, staged_candidate) do
    candidate = Settings.bump(staged_candidate, %{})

    case Persistence.write_candidate(candidate, payload.root) do
      :ok -> complete_settings_update(command, payload, id, candidate)
      {:error, reason} -> fail_settings_update(command, payload, candidate, reason)
    end
  end

  defp reject_settings_update(command, payload, reason) do
    finish(
      :idle,
      :update_settings,
      :idle,
      put_result(payload, command.id, {:error, reason})
    )
  end

  defp complete_settings_update(command, payload, id, candidate) do
    pending = %{
      id: id,
      phase: :confirmation,
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

    finish(:idle, :update_settings, :needs_confirmation, payload)
  end

  defp fail_settings_update(command, payload, candidate, reason) do
    fail_candidate_application(
      :update_settings,
      command,
      payload,
      candidate,
      reason,
      command.scope
    )
  end

  defp fail_candidate_application(event, command, payload, candidate, reason, scope) do
    case restore_and_clear(payload, candidate, scope) do
      :ok ->
        payload =
          payload
          |> Map.merge(%{pending: nil, last_error: reason})
          |> put_result(command.id, {:error, reason})
          |> configure_access()
          |> refresh_diagnostics()
          |> notify()

        finish(:idle, event, :idle, payload)

      {:error, rollback_reason} ->
        context = %{
          candidate: candidate,
          scope: scope,
          reason: reason,
          reply_id: nil,
          attempt: 1,
          retry_at: nil
        }

        error = {:rollback_failed, rollback_reason}

        payload =
          payload
          |> Map.merge(%{
            pending: nil,
            rollback_context: context,
            rollback_effect: %{ref: make_ref()},
            last_error: error,
            attempt: 1,
            retry_at: nil
          })
          |> put_result(command.id, {:error, reason})
          |> refresh_diagnostics()

        finish(:idle, event, :rolling_back, payload, error: error, attempt: 1)
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
    change = %{
      id: change_id(),
      kind: kind,
      command_id: command_id,
      desired: desired,
      settings: Settings.bump(payload.current, runtime_setting(kind, desired)),
      effect: %{ref: make_ref()}
    }

    finish(
      :idle,
      runtime_change_event(kind),
      :persisting_runtime_change,
      %{payload | runtime_change: change}
    )
  end

  defp persisted_runtime_change(
         {ref, outcome},
         %{runtime_change: %{effect: %{ref: ref}} = change} = payload
       ) do
    case persistence_result(outcome) do
      :ok ->
        dispatch_result = dispatch_runtime_change(payload.ops, change)

        payload =
          payload
          |> Map.merge(%{
            current: change.settings,
            runtime_change: nil,
            last_error: dispatch_error(dispatch_result)
          })
          |> put_result(change.command_id, runtime_change_result(change))
          |> refresh_diagnostics()

        finish(
          :persisting_runtime_change,
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
          :persisting_runtime_change,
          :runtime_change_persistence_completed,
          :idle,
          payload
        )
    end
  end

  defp persisted_runtime_change({_ref, _outcome}, _payload),
    do: {:error, :stale_runtime_change_completion}

  defp runtime_change_result(%{kind: :ssh}), do: :ok

  defp runtime_change_result(%{kind: :subnet_router, settings: settings}),
    do: {:ok, Settings.public(settings).subnet_router}

  defp dispatch_error(:ok), do: nil
  defp dispatch_error({:ok, _value}), do: nil
  defp dispatch_error({:error, reason}), do: {:runtime_dispatch_failed, reason}
  defp dispatch_error(invalid), do: {:invalid_runtime_dispatch_result, invalid}

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
    do: Diagnostics.request(server, event, payload, timeout)

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
    case restore_runtime(payload.current, payload.recovered_candidate, payload.ops, :complete) do
      :ok ->
        case Persistence.clear_candidate(payload.root) do
          :ok ->
            %{
              payload
              | recovered_candidate: nil,
                last_error: :recovered_unkept_configuration
            }

          {:error, reason} ->
            %{payload | last_error: {:candidate_cleanup_failed, reason}}
        end

      {:error, failures} ->
        %{payload | last_error: {:rollback_failed, failures}}
    end
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

  defp begin_rollback(state, event, reply_id, reason, payload) do
    context = %{
      candidate: payload.pending.candidate,
      scope: payload.pending.scope,
      reason: reason,
      reply_id: reply_id,
      attempt: 0,
      retry_at: nil
    }

    payload = %{
      payload
      | rollback_context: context,
        rollback_effect: %{ref: make_ref()},
        last_error: nil
    }

    finish(state, event, :rolling_back, refresh_diagnostics(payload))
  end

  defp run_rollback(%{rollback_context: context} = payload),
    do: restore_and_clear(payload, context.candidate, context.scope)

  defp restore_and_clear(payload, candidate, scope) do
    case restore_runtime(payload.current, candidate, payload.ops, scope) do
      :ok -> Persistence.clear_candidate(payload.root)
      {:error, _reason} = error -> error
    end
  end

  defp complete_rollback({:returned, :ok}, payload) do
    context = payload.rollback_context

    payload =
      payload
      |> Map.merge(%{
        pending: nil,
        recovered_candidate: nil,
        rollback_effect: nil,
        rollback_context: nil,
        last_error: context.reason,
        attempt: 0,
        retry_at: nil
      })
      |> maybe_put_rollback_result(context.reply_id, :ok)
      |> configure_access()
      |> refresh_diagnostics()
      |> notify()

    finish(:rolling_back, :rollback_completed, :idle, payload)
  end

  defp complete_rollback({:returned, {:error, reason}}, payload),
    do: rollback_failed(payload, reason)

  defp complete_rollback(:timed_out, payload),
    do: rollback_failed(payload, :rollback_timed_out)

  defp complete_rollback(:cancelled, payload),
    do: rollback_failed(payload, :rollback_cancelled)

  defp complete_rollback({:crashed, _kind, _reason, _stack}, payload),
    do: rollback_failed(payload, :rollback_crashed)

  defp complete_rollback(_invalid, payload),
    do: rollback_failed(payload, :invalid_rollback_result)

  defp rollback_failed(payload, reason) do
    context = payload.rollback_context
    attempt = context.attempt + 1
    delay = min(:timer.seconds(5), :timer.seconds(attempt))
    retry_at = System.monotonic_time(:millisecond) + delay
    error = {:rollback_failed, reason}

    context = %{
      context
      | attempt: attempt,
        retry_at: retry_at,
        reply_id: nil
    }

    payload =
      payload
      |> Map.merge(%{
        rollback_effect: nil,
        rollback_context: context,
        last_error: error,
        attempt: attempt,
        retry_at: retry_at
      })
      |> maybe_put_rollback_result(payload.rollback_context.reply_id, {:error, error})
      |> refresh_diagnostics()

    finish(
      :rolling_back,
      :rollback_completed,
      :rolling_back,
      payload,
      error: error,
      attempt: attempt,
      retry_at: retry_at
    )
  end

  defp retry_due?(%{retry_at: retry_at}),
    do: is_nil(retry_at) or System.monotonic_time(:millisecond) >= retry_at

  defp maybe_put_rollback_result(payload, nil, _result), do: payload

  defp maybe_put_rollback_result(payload, reply_id, result),
    do: put_result(payload, reply_id, result)

  defp restore_runtime(current, _candidate, ops, :internet) do
    ops.internet_restore.(Settings.internet(current))
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

  defp put_result(payload, relay, result), do: %{payload | reply: {relay, result}}

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
