defmodule NervesGate.Network.Runtime do
  @moduledoc """
  Safety boundary for durable trials, bounded hardware workers and the independent
  rollback watchdog. Jido chooses normal-path progression; this runtime enforces
  every effect's preconditions and restores on deadline, crash or failed I/O.
  Command acknowledgements are private, asynchronous and never enter agent state.
  """
  use GenServer
  alias NervesGate.{AtomicFile, Command, Config, Observations}
  alias NervesGate.Network.{Access, Adapter, Policy, Recovery, Signals, Trial, TrialStore}

  def via(id) do
    {:via, Registry, {NervesGate.Registry, {:network_runtime, id}}}
  end

  def agent_via(id) do
    {:via, Registry, {NervesGate.Registry, {:network_agent, id}}}
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(opts[:id]))
  end

  def status(server) do
    GenServer.call(server, :status)
  end

  def admission(server) do
    GenServer.call(server, :admission)
  end

  def execute(server, effect, context) do
    GenServer.call(server, {:execute, effect, context})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = Keyword.get(opts, :path, Config.path())
    storage = Keyword.get(opts, :storage, AtomicFile)
    adapter = Keyword.get(opts, :adapter, Application.fetch_env!(:nerves_gate, :network_adapter))
    {config, error} = load_config(path, storage)

    state = %{
      id: opts[:id],
      incarnation: Command.id(),
      path: path,
      storage: storage,
      adapter: adapter,
      config: config,
      error: error,
      trial: nil,
      deadline: nil,
      timer: nil,
      recovering: false,
      observed: nil,
      worker: nil,
      owner: nil,
      trial_ms: Keyword.get(opts, :trial_ms, 60_000),
      poll_ms: Keyword.get(opts, :poll_ms, 1000),
      effect_ms: Keyword.get(opts, :effect_ms, 10_000),
      sequence: 0,
      last_notice: nil,
      observation_timer: nil,
      last_trial_id: nil,
      proposal_reply: nil,
      workflow_hint: nil,
      workflow_at: nil
    }

    Observations.subscribe(Observations.sources(adapter))
    state = restored(state, initial_recovery(state))
    schedule_poll(state)
    {:ok, state |> refresh() |> publish()}
  end

  @impl true
  def handle_call(query, _, state) when query in [:status, :admission] do
    next = refresh(state)

    next =
      if public(next) != public(state) do
        publish(next)
      else
        next
      end

    result =
      if query == :admission do
        Map.put(public(next), :workflow, workflow(next))
      else
        public(next)
      end

    {:reply, result, next}
  end

  def handle_call(:observations, _, state) do
    sources = [
      {Observations.table(), Observations.workflow("network", state.id)}
      | Observations.sources(state.adapter)
    ]

    {:reply, sources, state}
  end

  def handle_call({:execute, effect, context}, _, state) do
    state = refresh(state)

    case Command.check_revision(Map.get(context, :expected_revision), public(state)) do
      :ok ->
        {result, next} = execute_effect(effect, context, state)
        {:reply, result, publish(next)}

      error ->
        {:reply, error, state}
    end
  end

  defp execute_effect(_, _, %{worker: worker} = state) when not is_nil(worker) do
    {{:error, :recovery_in_progress}, state}
  end

  defp execute_effect(%{operation: :propose} = effect, context, state) do
    with :ok <- Policy.available(public(state)),
         {:ok, network} <- Config.validate_network(effect.network) do
      auto =
        not state.config["setup_completed"] and
          Access.usb?(state.observed, Map.get(context, :access))

      timeout =
        if auto do
          15_000
        else
          state.trial_ms
        end

      record = %{Trial.new(state.config, network, auto, timeout) | "id" => effect.id}
      timer = Process.send_after(self(), {:expire, effect.id}, timeout)
      owner = Process.monitor(GenServer.whereis(agent_via(state.id)))

      state = %{
        state
        | trial: record,
          timer: timer,
          deadline: now() + timeout,
          owner: owner,
          last_trial_id: effect.id,
          error: nil,
          proposal_reply: %{context: context, result: {:ok, effect.id}}
      }

      state = emit(state, "network.configuration.proposed", effect.id, :applying)

      {:pending,
       start_work(state, :apply, nil, {:ok, effect.id}, fn ->
         prepare_and_apply(state, record, network)
       end)}
    else
      error -> {error, state}
    end
  end

  defp execute_effect(%{operation: operation, id: id}, context, state) do
    case Policy.matching(public(state), id) do
      :ok -> execute_trial(operation, context, state)
      error -> {error, state}
    end
  end

  defp prepare_and_apply(state, record, network) do
    case TrialStore.prepare(record, state.path, state.storage) do
      :ok ->
        case Adapter.apply_config(state.adapter, network) do
          :ok -> :ok
          {:error, reason} -> {:error, {:apply, reason}}
        end

      {:error, reason} ->
        {:error, {:save, reason}}
    end
  end

  defp execute_trial(:cancel, context, state) do
    {:pending, recover(state, nil, context, :ok)}
  end

  defp execute_trial(:confirm, context, state) do
    cond do
      now() >= state.deadline -> {:pending, expire(state, context)}
      not ready?(state) -> {{:error, :not_connected}, state}
      true -> {:pending, commit(state, context, :ok)}
    end
  end

  defp execute_trial(operation, context, state)
       when operation in [:auto_confirm, :auto_cancel, :await] do
    cond do
      not state.trial["auto_save"] -> {{:error, :confirmation_required}, state}
      now() >= state.deadline -> {:pending, expire(state, context)}
      true -> automatic_effect(operation, context, state)
    end
  end

  # Veto stale decisions; never substitute a different normal-path effect.
  defp automatic_effect(:auto_confirm, context, state) do
    if ready?(state) do
      {:pending, commit(state, context, :ok)}
    else
      {{:error, :not_connected}, state}
    end
  end

  defp automatic_effect(:auto_cancel, context, state) do
    if conflicted?(state) do
      {:pending, recover(state, :conflicting_networks, context, {:error, :conflicting_networks})}
    else
      {{:error, :stale_decision}, state}
    end
  end

  defp automatic_effect(:await, _, state) do
    if not ready?(state) and not conflicted?(state) do
      {:ok, finish_proposal(state)}
    else
      {{:error, :stale_decision}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{worker: %{task: %{ref: ref}} = worker} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(worker.timer)
    {:noreply, complete(%{state | worker: nil}, worker, result) |> publish()}
  end

  def handle_info(
        {:DOWN, ref, :process, _, reason},
        %{worker: %{task: %{ref: ref}} = worker} = state
      ) do
    Process.cancel_timer(worker.timer)
    {:noreply, failed_work(%{state | worker: nil}, worker, {:worker_failed, reason}) |> publish()}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref, trial: trial} = state)
      when not is_nil(trial) do
    {:noreply, interrupt(%{state | owner: nil}, :agent_restarted) |> publish()}
  end

  def handle_info({:work_timeout, ref}, %{worker: %{task: %{ref: ref}}} = state) do
    {:noreply, interrupt(state, :operation_timeout) |> publish()}
  end

  def handle_info({:expire, id}, %{trial: %{"id" => id}} = state) do
    {:noreply, expire(state, nil) |> publish()}
  end

  def handle_info(:poll, state) do
    Observations.subscribe(Observations.sources(state.adapter))
    schedule_poll(state)
    {:noreply, reconcile(state)}
  end

  def handle_info(:observations_changed, state) do
    {:noreply, reconcile(%{state | observation_timer: nil})}
  end

  def handle_info(%PropertyTable.Event{}, state) do
    {:noreply, observe_later(state)}
  end

  def handle_info({VintageNet, _, _, _, _}, state) do
    {:noreply, observe_later(state)}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  defp observe_later(%{observation_timer: nil} = state) do
    %{state | observation_timer: Process.send_after(self(), :observations_changed, 20)}
  end

  defp observe_later(state) do
    state
  end

  defp reconcile(state) do
    state |> refresh() |> maintain() |> publish()
  end

  @impl true
  def terminate(_, %{worker: worker}) do
    if worker do
      Task.shutdown(worker.task, :brutal_kill)
    end

    :ok
  end

  defp start_work(state, kind, context, reply, fun) do
    task =
      Task.async(fn ->
        try do
          fun.()
        catch
          type, reason -> {:error, {type, reason}}
        end
      end)

    timer = Process.send_after(self(), {:work_timeout, task.ref}, state.effect_ms)
    %{state | worker: %{task: task, timer: timer, kind: kind, context: context, reply: reply}}
  end

  defp complete(state, %{kind: :apply}, :ok) do
    state = refresh(state)
    state = emit(state, "network.configuration.applied", state.trial["id"], :pending)

    cond do
      now() >= state.deadline -> expire(state, nil)
      state.trial["auto_save"] -> state
      true -> finish_proposal(state)
    end
  end

  defp complete(state, %{kind: :commit} = worker, {:committed, config, cleanup}) do
    id = state.trial["id"]
    state = clear_trial(%{state | config: config, error: nil})

    state =
      case cleanup do
        :ok -> state
        {:error, reason} -> %{state | recovering: true, error: {:restore, reason}}
      end

    reply(worker, worker.reply)
    state |> finish_proposal() |> emit("network.trial.confirmed", id, :idle)
  end

  defp complete(state, %{kind: :commit} = worker, {:error, reason, _decision}) do
    recover(state, reason, worker.context, {:error, reason})
  end

  defp complete(state, %{kind: :restore} = worker, {:reconciled, result, decision}) do
    state = restored(state, result)
    reply(worker, recovery_reply(worker.reply, state))
    type = recovery_event(state.recovering, decision)

    state
    |> finish_proposal()
    |> emit(
      type,
      worker.reply_id,
      if state.recovering do
        :recovering
      else
        :idle
      end
    )
    |> refresh()
  end

  defp complete(state, worker, {:error, reason}) do
    failed_work(state, worker, reason)
  end

  defp failed_work(state, %{kind: :restore} = worker, reason) do
    reply(worker, {:error, {:restore, reason}})
    %{state | recovering: true, error: {:restore, reason}} |> finish_proposal()
  end

  defp failed_work(state, worker, reason) do
    recover(state, reason, worker.context, {:error, reason})
  end

  defp commit(state, context, response) do
    start_work(state, :commit, context, response, fn ->
      case TrialStore.confirm(state.trial, state.path, state.storage) do
        {:ok, record} ->
          {:committed, record["requested"], TrialStore.clear(state.path, state.storage)}

        error ->
          error
      end
    end)
  end

  defp recover(state, reason, context, response) do
    id =
      if state.trial do
        state.trial["id"]
      else
        nil
      end

    state =
      state
      |> fail_proposal(reason || :cancelled)
      |> Map.merge(%{recovering: true, error: reason})
      |> clear_trial()

    next =
      start_work(state, :restore, context, response, fn ->
        decision =
          case TrialStore.load(state.path, state.storage) do
            {:ok, %{"phase" => phase}} -> phase
            _ -> nil
          end

        {:reconciled, Recovery.restore(state.path, state.adapter, state.storage), decision}
      end)

    %{next | worker: Map.put(next.worker, :reply_id, id)}
  end

  defp interrupt(state, reason) do
    {state, context} = stop_work(state)
    recover(state, reason, context, {:error, reason})
  end

  defp expire(state, context) do
    state = emit(state, "network.trial.expired", state.trial["id"], :recovering)
    {state, waiting} = stop_work(state)
    recover(state, :expired, context || waiting, {:error, :expired})
  end

  defp stop_work(%{worker: nil} = state) do
    {state, nil}
  end

  defp stop_work(%{worker: worker} = state) do
    Task.shutdown(worker.task, :brutal_kill)
    Process.cancel_timer(worker.timer)
    {%{state | worker: nil}, worker.context}
  end

  defp maintain(%{trial: %{"auto_save" => true}, deadline: deadline} = state) do
    if now() >= deadline do
      expire(state, nil)
    else
      state
    end
  end

  defp maintain(%{worker: worker} = state) when not is_nil(worker) do
    state
  end

  defp maintain(%{recovering: true} = state) do
    recover(state, state.error, nil, :ok)
  end

  defp maintain(state) do
    state
  end

  defp restored(state, {:ok, config}) do
    error =
      if match?({:restore, _}, state.error) do
        nil
      else
        state.error
      end

    %{state | config: config, recovering: false, error: error}
  end

  defp restored(state, {:error, reason}) do
    %{state | recovering: true, error: reason}
  end

  defp clear_trial(state) do
    if state.timer do
      Process.cancel_timer(state.timer)
    end

    if state.owner do
      Process.demonitor(state.owner, [:flush])
    end

    %{state | trial: nil, deadline: nil, timer: nil, owner: nil}
  end

  defp finish_proposal(%{proposal_reply: nil} = state) do
    state
  end

  defp finish_proposal(%{proposal_reply: pending} = state) do
    Command.reply(pending.context, pending.result)
    %{state | proposal_reply: nil}
  end

  defp fail_proposal(%{proposal_reply: nil} = state, _) do
    state
  end

  defp fail_proposal(state, reason) do
    put_in(state.proposal_reply.result, {:error, reason})
  end

  defp refresh(state) do
    case Adapter.snapshot(state.adapter) do
      {:ok, observed} -> %{state | observed: observed}
      {:error, reason} -> %{state | observed: nil, error: {:discovery, reason}}
    end
  end

  defp public(state) do
    %{
      revision: "#{state.incarnation}:#{state.sequence}",
      config: state.config,
      trial:
        if state.trial do
          Trial.public(state.trial)
        end,
      observed: state.observed,
      error: state.error,
      recovering: state.recovering,
      ready: ready?(state)
    }
  end

  defp ready?(%{trial: nil}) do
    false
  end

  defp ready?(state) do
    Policy.ready?(state.observed, state.trial["requested"]["network"])
  end

  defp conflicted?(state) do
    Policy.conflicts(state.observed, state.trial["requested"]["network"]) != []
  end

  defp workflow(state) do
    %{
      incarnation: state.incarnation,
      sequence: state.sequence,
      phase: phase(state),
      trial_id:
        if state.trial do
          state.trial["id"]
        else
          state.last_trial_id
        end,
      proposal_reply_pending: state.proposal_reply != nil
    }
  end

  defp phase(%{recovering: true}) do
    :recovering
  end

  defp phase(%{worker: %{kind: :apply}}) do
    :applying
  end

  defp phase(%{worker: %{kind: :commit}}) do
    :confirming
  end

  defp phase(%{trial: trial}) when not is_nil(trial) do
    :pending
  end

  defp phase(_) do
    :idle
  end

  defp emit(state, type, id, phase) do
    state = %{state | sequence: state.sequence + 1, last_notice: {id, phase}}
    signal = Signals.new(type, id, phase, state.sequence, state.incarnation)
    notify_agent(state, signal)
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "network:events", signal)
    state
  end

  defp publish(state) do
    workflow = workflow(state)

    state =
      if state.last_notice == {workflow.trial_id, workflow.phase} do
        state
      else
        emit(state, "network.runtime.reconciled", workflow.trial_id, workflow.phase)
      end

    Observations.put(
      Observations.workflow("network", state.id),
      Map.delete(public(state), :observed)
    )

    hint_workflow(state)
  end

  # Readiness hints plus bounded reconciliation, not one turn per property event.
  # These requests do not increment the public form revision.
  defp hint_workflow(%{trial: trial, worker: nil, recovering: false} = state)
       when not is_nil(trial) do
    signature = {trial["id"], ready?(state), conflicted?(state), state.proposal_reply != nil}

    if signature != state.workflow_hint or state.workflow_at == nil or
         now() - state.workflow_at >= 1000 do
      notify_agent(
        state,
        Signals.new(
          "network.workflow.reconcile",
          trial["id"],
          :pending,
          state.sequence,
          state.incarnation
        )
      )

      %{state | workflow_hint: signature, workflow_at: now()}
    else
      state
    end
  end

  defp hint_workflow(state) do
    %{state | workflow_hint: nil, workflow_at: nil}
  end

  defp notify_agent(state, signal) do
    if pid = GenServer.whereis(agent_via(state.id)) do
      Jido.AgentServer.cast(pid, signal)
    end

    :ok
  end

  defp initial_recovery(state) do
    task = Task.async(fn -> Recovery.restore(state.path, state.adapter, state.storage) end)

    case Task.yield(task, state.effect_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, {:restore, :operation_timeout}}
    end
  end

  defp recovery_event(true, _) do
    "network.configuration.failed"
  end

  defp recovery_event(false, "pending") do
    "network.trial.rolled_back"
  end

  defp recovery_event(false, "confirmed") do
    "network.trial.confirmed"
  end

  defp recovery_event(false, _) do
    "network.runtime.reconciled"
  end

  defp recovery_reply({:error, _} = original, _state) do
    original
  end

  defp recovery_reply(_, %{recovering: true, error: error}) do
    {:error, error}
  end

  defp recovery_reply(original, _state) do
    original
  end

  defp reply(%{context: nil}, _) do
    :ok
  end

  defp reply(%{context: context}, result) do
    Command.reply(context, result)
  end

  defp load_config(path, storage) do
    case Config.load(path, storage) do
      {:ok, config} -> {config, nil}
      {:error, reason} -> {nil, {:load, reason}}
    end
  end

  defp schedule_poll(state) do
    Process.send_after(self(), :poll, state.poll_ms)
  end

  defp now do
    System.monotonic_time(:millisecond)
  end
end
