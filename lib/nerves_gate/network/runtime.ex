defmodule NervesGate.Network.Runtime do
  @moduledoc """
  Temporary LAN trials with an independent rollback timer. Ordinary GenServer
  calls are replied to after hardware work; callers do not own that work.
  VintageNet owns saved settings. Jido decides first-USB-setup auto-save.
  """
  use GenServer
  alias NervesGate.{Config, Observations, Remote}
  alias NervesGate.Network.{Access, Adapter, Policy}
  alias NervesGate.Remote.Sharing, as: Routes

  def via(id), do: {:via, Registry, {NervesGate.Registry, {:network_runtime, id}}}
  def agent_via(id), do: {:via, Registry, {NervesGate.Registry, {:network_agent, id}}}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(opts[:id]))
  def status(server), do: GenServer.call(server, :status)

  def admission(server) do
    GenServer.call(server, :admission)
  end

  def execute(server, effect), do: GenServer.call(server, {:execute, effect})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    adapter = Keyword.get(opts, :adapter, Application.fetch_env!(:nerves_gate, :network_adapter))
    effect_ms = Keyword.get(opts, :effect_ms, 10_000)
    {config, error} = load(adapter, effect_ms)

    state = %{
      id: opts[:id],
      adapter: adapter,
      remote: Keyword.get(opts, :remote, NervesGate.Remote),
      config: config,
      error: error,
      trial: nil,
      deadline: nil,
      timer: nil,
      owner: nil,
      worker: nil,
      proposal_reply: nil,
      recovering: match?({:restore, _}, error),
      observed: nil,
      trial_ms: Keyword.get(opts, :trial_ms, 60_000),
      poll_ms: Keyword.get(opts, :poll_ms, 1000),
      effect_ms: effect_ms,
      observation_timer: nil
    }

    Observations.subscribe(sources(state))
    send(self(), :poll)
    {:ok, state |> refresh() |> publish()}
  end

  @impl true
  def handle_call(:status, _, state) do
    state = refresh(state)
    {:reply, Map.put(public(state), :sharing_admission, lan_change(state)), state}
  end

  def handle_call(:admission, _, state) do
    state = refresh(state)
    {:reply, public(state), state}
  end

  def handle_call(:observations, _, state) do
    {:reply, sources(state), state}
  end

  def handle_call({:scan, equipment}, from, state) do
    state = refresh(state)

    with :ok <- Policy.available(public(state)),
         {:ok, scope} <- NervesGate.Equipment.Subnet.active(public(state)) do
      {:noreply,
       work(state, :scan, from, fn -> NervesGate.Equipment.scan(scope, equipment) end)
       |> publish()}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:sharing, operation, params}, from, state) do
    state = refresh(state)

    with :ok <- Policy.available(public(state)),
         {:ok, params} <- sharing_params(operation, params, state) do
      {:noreply, share(state, operation, params, from) |> publish()}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:propose, network, access}, from, state) do
    state |> refresh() |> propose(network, access, from) |> respond()
  end

  def handle_call({operation, id}, from, state) when operation in [:confirm, :cancel] do
    execute_trial(operation, id, from, refresh(state)) |> respond()
  end

  def handle_call({:execute, effect}, _, state) do
    {result, state} = execute_trial(effect.operation, effect.id, nil, refresh(state))
    {:reply, result, publish(state)}
  end

  defp respond({:pending, state}), do: {:noreply, publish(state)}
  defp respond({result, state}), do: {:reply, result, publish(state)}

  defp propose(state, input, access, from) do
    with :ok <- Policy.available(public(state)),
         {:ok, network} <- Config.validate_network(input),
         :ok <- lan_change(state),
         agent when is_pid(agent) <- GenServer.whereis(agent_via(state.id)) do
      auto = not state.config["setup_completed"] and Access.usb?(state.observed, access)
      timeout = if auto, do: 15_000, else: state.trial_ms

      trial = %{
        id: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
        network: network,
        auto_save: auto,
        expires_at: System.system_time(:millisecond) + timeout
      }

      state = %{
        state
        | trial: trial,
          deadline: now() + timeout,
          error: nil,
          timer: Process.send_after(self(), {:expire, trial.id}, timeout),
          owner: Process.monitor(agent),
          proposal_reply: {from, {:ok, trial.id}}
      }

      {:pending, work(state, :apply, nil, fn -> Adapter.apply_config(state.adapter, network) end)}
    else
      nil -> {{:error, :unavailable}, state}
      error -> {error, state}
    end
  end

  defp execute_trial(_, _, _, %{worker: worker} = state) when not is_nil(worker),
    do: {{:error, :recovery_in_progress}, state}

  defp execute_trial(operation, id, from, state) do
    case Policy.matching(public(state), id) do
      :ok -> execute(operation, from, state)
      error -> {error, state}
    end
  end

  defp execute(:cancel, from, state),
    do: {:pending, restore(state, :cancelled, from, :ok)}

  defp execute(:confirm, from, state) do
    cond do
      now() >= state.deadline -> {:pending, expire(state, from)}
      not ready?(state) -> {{:error, :not_connected}, state}
      true -> {:pending, save(state, from)}
    end
  end

  defp execute(operation, _, state) when operation in [:auto_confirm, :auto_cancel, :await] do
    cond do
      not state.trial.auto_save -> {{:error, :confirmation_required}, state}
      now() >= state.deadline -> {:pending, expire(state, nil)}
      true -> execute_auto(operation, state)
    end
  end

  defp execute_auto(operation, state) do
    case {operation, ready?(state), conflicted?(state)} do
      {:auto_confirm, true, _} ->
        {:pending, save(state, nil)}

      {:auto_cancel, _, true} ->
        {:pending, restore(state, :conflicting_networks, nil, {:error, :conflicting_networks})}

      {:await, false, false} ->
        {:ok, finish_proposal(state)}

      _ ->
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

    {:noreply,
     complete(%{state | worker: nil}, worker, {:error, {:worker_failed, reason}}) |> publish()}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref, trial: trial} = state)
      when not is_nil(trial),
      do: {:noreply, interrupt(state, :agent_restarted) |> publish()}

  def handle_info({:work_timeout, ref}, %{worker: %{task: %{ref: ref}}} = state),
    do: {:noreply, interrupt(state, :operation_timeout) |> publish()}

  def handle_info({:expire, id}, %{trial: %{id: id}} = state),
    do: {:noreply, expire(state, nil) |> publish()}

  def handle_info(:poll, state) do
    Observations.subscribe(sources(state))
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, reconcile(state)}
  end

  def handle_info(:observations_changed, state),
    do: {:noreply, reconcile(%{state | observation_timer: nil})}

  def handle_info(%PropertyTable.Event{}, state), do: {:noreply, observe_later(state)}
  def handle_info({VintageNet, _, _, _, _}, state), do: {:noreply, observe_later(state)}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{worker: %{task: task}}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_, _), do: :ok

  defp observe_later(%{observation_timer: nil} = state),
    do: %{state | observation_timer: Process.send_after(self(), :observations_changed, 20)}

  defp observe_later(state), do: state

  defp reconcile(state) do
    state = refresh(state)

    state =
      cond do
        state.trial != nil and now() >= state.deadline -> expire(state, nil)
        state.recovering and state.worker == nil -> restore(state, state.error, nil, :ok)
        true -> reconcile_sharing(state)
      end

    publish(state)
  end

  defp work(state, operation, from, fun) do
    task = Task.async(fun)
    timeout = if operation == :sharing, do: 65_000, else: state.effect_ms
    timer = Process.send_after(self(), {:work_timeout, task.ref}, timeout)
    %{state | worker: %{task: task, timer: timer, operation: operation, from: from}}
  end

  defp complete(state, %{operation: :sharing, from: from}, result) do
    reply(
      from,
      case result do
        {:ok, _routes} -> :ok
        error -> error
      end
    )

    state
  end

  defp complete(state, %{operation: :scan, from: from}, result) do
    reply(from, result)
    state
  end

  defp complete(state, %{operation: :apply}, :ok) do
    state = refresh(state)

    cond do
      now() >= state.deadline -> expire(state, nil)
      state.trial.auto_save -> state
      true -> finish_proposal(state)
    end
  end

  defp complete(state, %{operation: :save, from: from}, :ok) do
    state = %{state | config: Config.from_network(state.trial.network), error: nil}
    reply(from, :ok)
    state |> clear_trial() |> finish_proposal()
  end

  defp complete(state, %{operation: :restore, from: {from, result}}, outcome) do
    error =
      case outcome do
        :ok -> nil
        {:error, reason} -> {:restore, reason}
      end

    reply(from, if(error, do: {:error, error}, else: result))
    previous = if match?({:restore, _}, state.error), do: nil, else: state.error

    %{state | recovering: error != nil, error: error || previous}
    |> finish_proposal()
    |> refresh()
  end

  defp complete(state, %{operation: operation, from: from}, {:error, reason}) do
    reason = if operation == :save, do: {:save, reason}, else: {:apply, reason}
    restore(state, reason, from, {:error, reason})
  end

  defp save(state, from),
    do: work(state, :save, from, fn -> Adapter.save(state.adapter, state.trial.network) end)

  defp restore(state, reason, from, result) do
    state =
      case state.proposal_reply do
        {caller, _} -> %{state | proposal_reply: {caller, {:error, reason}}}
        nil -> state
      end
      |> clear_trial()

    state = %{state | recovering: true, error: if(reason == :cancelled, do: nil, else: reason)}

    work(state, :restore, {from, result}, fn ->
      Adapter.restore(state.adapter, state.config["network"])
    end)
  end

  defp interrupt(%{worker: %{operation: operation} = worker} = state, reason)
       when operation in [:sharing, :scan] do
    {state, _} = stop_work(state)
    complete(state, worker, {:error, reason})
  end

  defp interrupt(state, reason) do
    {state, from} = stop_work(state)
    restore(state, reason, from, {:error, reason})
  end

  defp expire(state, from) do
    {state, waiting} = stop_work(state)
    restore(state, :expired, from || waiting, {:error, :expired})
  end

  defp stop_work(%{worker: nil} = state), do: {state, nil}

  defp stop_work(%{worker: worker} = state) do
    Task.shutdown(worker.task, :brutal_kill)
    Process.cancel_timer(worker.timer)
    from = if worker.operation == :restore, do: elem(worker.from, 0), else: worker.from
    {%{state | worker: nil}, from}
  end

  defp clear_trial(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.owner, do: Process.demonitor(state.owner, [:flush])
    %{state | trial: nil, deadline: nil, timer: nil, owner: nil}
  end

  defp finish_proposal(%{proposal_reply: nil} = state), do: state

  defp finish_proposal(%{proposal_reply: {from, result}} = state) do
    reply(from, result)
    %{state | proposal_reply: nil}
  end

  defp reply(nil, _), do: :ok
  defp reply(from, result), do: GenServer.reply(from, result)

  defp refresh(state) do
    case Adapter.snapshot(state.adapter) do
      nil -> %{state | observed: nil, error: {:discovery, :unavailable}}
      observed -> %{state | observed: observed}
    end
  end

  defp public(state) do
    %{
      config: state.config,
      trial: state.trial,
      observed: state.observed,
      error: state.error,
      recovering: state.recovering,
      ready: ready?(state),
      phase: phase(state),
      proposal_reply_pending: state.proposal_reply != nil
    }
  end

  defp ready?(%{trial: nil}), do: false
  defp ready?(state), do: Policy.ready?(state.observed, state.trial.network)
  defp conflicted?(state), do: Policy.conflicts(state.observed, state.trial.network) != []
  defp phase(%{worker: %{operation: operation}}), do: operation
  defp phase(%{recovering: true}), do: :restore
  defp phase(%{trial: nil}), do: :idle
  defp phase(_), do: :pending

  defp sources(state),
    do: [
      {Observations.table(), Observations.workflow("network", state.id)}
      | Observations.sources(state.adapter)
    ]

  defp publish(state) do
    Observations.put(
      Observations.workflow("network", state.id),
      Map.delete(public(state), :observed)
    )

    if phase(state) == :pending and state.trial.auto_save do
      if pid = GenServer.whereis(agent_via(state.id)) do
        Jido.AgentServer.cast(pid, Jido.Signal.new!("network.reconcile", %{}, source: "/network"))
      end
    end

    state
  end

  defp load(adapter, timeout) do
    case bounded(fn -> Adapter.load(adapter) end, timeout) do
      {:ok, config} -> {config, restore_loaded(adapter, config, timeout)}
      {:error, reason} -> {nil, {:load, reason}}
    end
  end

  defp restore_loaded(adapter, config, timeout) do
    case bounded(fn -> Adapter.restore(adapter, config["network"]) end, timeout) do
      :ok -> nil
      {:error, reason} -> {:restore, reason}
    end
  end

  defp bounded(fun, timeout) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:worker_failed, reason}}
      nil -> {:error, :operation_timeout}
    end
  end

  defp lan_change(state), do: remote_snapshot(state.remote) |> Routes.lan_change()

  defp sharing_params(:sharing_enable, %{site: site, confirmed: confirmed}, state),
    do: Routes.enable(public(state), remote_snapshot(state.remote), site, confirmed)

  defp sharing_params(:sharing_disable, %{route: route}, _) do
    with {:ok, _} <- Routes.decode(route) do
      {:ok, %{route: route}}
    end
  end

  defp sharing_params(_, _, _), do: {:error, :sharing_route}

  defp share(state, operation, params, from) do
    work(state, :sharing, from, fn -> Remote.sharing(operation, params, state.remote) end)
  end

  defp reconcile_sharing(%{worker: nil, trial: nil, recovering: false} = state) do
    maybe_sync(state, remote_snapshot(state.remote))
  end

  defp reconcile_sharing(state), do: state

  # One read-only Controller barrier after Remote starts. Never replay a route write.
  defp maybe_sync(state, %{
         available: true,
         operation: nil,
         sharing: %{ready: false, uncertain: []}
       }),
       do: share(state, :sharing_sync, %{}, nil)

  defp maybe_sync(state, _), do: state

  defp remote_snapshot(server) do
    Remote.status(server)
  catch
    :exit, {_, {GenServer, :call, _}} -> Remote.unavailable()
  end

  defp now, do: System.monotonic_time(:millisecond)
end
