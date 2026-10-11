defmodule NervesGate.Remote.Runtime do
  @moduledoc """
  Owns one bounded daemon worker and cached public observations. An agent crash
  stops and joins its worker; a runtime crash kills the linked worker and restarts
  the agent. Neither event rolls back Tailscale preferences or retries a write.
  Daemon-side work may still finish, so interrupted outcomes are explicitly unknown.
  """
  use GenServer
  alias NervesGate.{Command, Observations}
  alias NervesGate.Remote.{Adapter, Policy, Signals}

  def via(id), do: {:via, Registry, {NervesGate.Registry, {:remote_runtime, id}}}
  def agent_via(id), do: {:via, Registry, {NervesGate.Registry, {:remote_agent, id}}}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(opts[:id]))
  def status(server), do: GenServer.call(server, :status)

  def execute(server, effect, context \\ %{}),
    do: GenServer.call(server, {:execute, effect, context})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      id: opts[:id],
      incarnation: Command.id(),
      adapter: Keyword.get(opts, :adapter, Application.fetch_env!(:nerves_gate, :remote_adapter)),
      task: nil,
      timer: nil,
      owner: nil,
      operation: nil,
      operation_id: nil,
      error: nil,
      snapshot: nil,
      revision: 0,
      sequence: 0,
      poll_ms: Keyword.get(opts, :poll_ms, 1_000),
      timeout: Keyword.get(opts, :timeout, 40_000)
    }

    Observations.subscribe(Observations.sources(state.adapter))
    send(self(), :poll)
    {:ok, refresh(state)}
  end

  @impl true
  def handle_call(:status, _, state) do
    state = refresh(state)
    {:reply, state.snapshot, state}
  end

  def handle_call(:observations, _, state) do
    sources = [
      {Observations.table(), Observations.workflow("remote", state.id)}
      | Observations.sources(state.adapter)
    ]

    {:reply, sources, state}
  end

  def handle_call({:execute, %{operation: :login_url}, _}, _, state) do
    # Only a transient explicit reply; never an Action result or agent outcome.
    url = state.adapter |> Adapter.login_url() |> Policy.login_url()
    {:reply, url, state}
  end

  def handle_call({:execute, effect, context}, _, state) do
    state = refresh(state)

    admission =
      with :ok <- Command.check_revision(Map.get(context, :expected_revision), state.snapshot),
           do: Policy.available(state.snapshot)

    case admission do
      :ok ->
        owner = Process.monitor(GenServer.whereis(agent_via(state.id)))

        task =
          Task.async(fn -> Adapter.execute(state.adapter, effect.operation, effect.params) end)

        timer = Process.send_after(self(), {:timeout, task.ref}, state.timeout)

        state =
          refresh(%{
            state
            | task: task,
              timer: timer,
              owner: owner,
              operation: Atom.to_string(effect.operation),
              operation_id: effect.id,
              error: nil
          })

        type =
          if effect.operation == :connect,
            do: "remote.connection.requested",
            else: "remote.operation.started"

        {:reply, :ok, emit(state, type)}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, complete(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, complete(state, {:error, :failed})}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref, task: %Task{} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, complete(state, {:error, :outcome_unknown})}
  end

  def handle_info({:timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, complete(state, {:error, :timeout})}
  end

  def handle_info(:poll, state) do
    Observations.subscribe(Observations.sources(state.adapter))
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, refresh(state)}
  end

  def handle_info(%PropertyTable.Event{}, state), do: {:noreply, refresh(state)}
  def handle_info({Tailscale, _, _, _, _}, state), do: {:noreply, refresh(state)}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{task: %Task{} = task}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_, _), do: :ok

  defp complete(state, result) do
    Process.cancel_timer(state.timer)
    Process.demonitor(state.owner, [:flush])
    error = Policy.result_error(result)

    type =
      cond do
        error == nil -> "remote.operation.completed"
        state.operation == "connect" -> "remote.enrollment.failed"
        true -> "remote.operation.failed"
      end

    %{state | task: nil, timer: nil, owner: nil, operation: nil, error: error}
    |> refresh()
    |> emit(type)
  end

  defp refresh(state) do
    snapshot =
      state.adapter
      |> Adapter.snapshot()
      |> Policy.sanitize()
      |> Map.merge(%{operation: state.operation, error: state.error})

    previous = state.snapshot
    changed = previous == nil or snapshot != Map.delete(previous, :revision)
    revision = state.revision + if(changed, do: 1, else: 0)
    snapshot = Map.put(snapshot, :revision, "#{state.incarnation}:#{revision}")
    state = %{state | snapshot: snapshot, revision: revision}

    Observations.put(Observations.workflow("remote", state.id), %{
      revision: snapshot.revision,
      operation: state.operation,
      operation_id: state.operation_id,
      error: state.error
    })

    state
    |> connection_transition(previous)
    |> availability_transition(previous)
  end

  defp connection_transition(state, nil), do: state

  defp connection_transition(%{snapshot: snapshot} = state, previous) do
    cond do
      snapshot.state == "online" and previous.state != "online" ->
        emit(state, "remote.connection.established")

      snapshot.state != "online" and previous.state == "online" ->
        emit(state, "remote.connection.lost")

      true ->
        state
    end
  end

  defp availability_transition(state, nil), do: state

  defp availability_transition(%{snapshot: snapshot} = state, previous) do
    if snapshot.available != previous.available do
      type =
        if snapshot.available, do: "remote.daemon.available", else: "remote.daemon.unavailable"

      emit(state, type)
    else
      state
    end
  end

  defp emit(state, type) do
    state = %{state | sequence: state.sequence + 1}
    phase = if state.task, do: :running, else: :idle
    signal = Signals.new(type, state.operation_id, phase, state.sequence, state.incarnation)

    if pid = GenServer.whereis(agent_via(state.id)), do: Jido.AgentServer.cast(pid, signal)
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "remote:events", signal)
    state
  end
end
