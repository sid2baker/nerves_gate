defmodule NervesGate.FSM.Effect do
  @moduledoc """
  Runs one bounded asynchronous operation owned by a lifecycle process.

  The helper supplies supervision, owner monitoring, timeout, cancellation,
  deduplication, and terminal-event delivery. It has no domain or retry logic.
  """

  @type outcome ::
          {:returned, term()}
          | {:crashed, Exception.kind(), term(), Exception.stacktrace()}
          | :timed_out
          | :cancelled

  @type event_builder :: (reference(), outcome() -> {atom(), term()})

  @spec start(pid(), reference(), (-> term()), event_builder(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start(owner, effect_ref, work, event_builder, options \\ [])
      when is_pid(owner) and is_reference(effect_ref) and is_function(work, 0) and
             is_function(event_builder, 2) do
    supervisor = Keyword.get(options, :supervisor, NervesGate.TaskSupervisor)
    registry = Keyword.get(options, :registry, NervesGate.EffectRegistry)
    timeout = Keyword.get(options, :timeout, 30_000)

    Task.Supervisor.start_child(supervisor, fn ->
      case Registry.register(registry, {owner, effect_ref}, nil) do
        {:ok, _owner} ->
          coordinate(supervisor, owner, effect_ref, timeout, work, event_builder)

        {:error, {:already_registered, _pid}} ->
          :ok
      end
    end)
  end

  @spec cancel(pid()) :: :ok
  def cancel(coordinator) when is_pid(coordinator) do
    send(coordinator, :cancel_effect)
    :ok
  end

  defp coordinate(supervisor, owner, effect_ref, timeout, work, event_builder) do
    owner_monitor = Process.monitor(owner)
    coordinator = self()

    {:ok, worker} =
      Task.Supervisor.start_child(supervisor, fn ->
        outcome = execute(work)
        send(coordinator, {:effect_terminal, self(), outcome})
      end)

    worker_monitor = Process.monitor(worker)

    receive do
      {:effect_terminal, ^worker, outcome} ->
        Process.demonitor(worker_monitor, [:flush])
        deliver(owner, effect_ref, outcome, event_builder)

      {:DOWN, ^worker_monitor, :process, ^worker, reason} ->
        deliver(owner, effect_ref, {:crashed, :exit, reason, []}, event_builder)

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        terminate_worker(supervisor, worker)

      :cancel_effect ->
        terminate_worker(supervisor, worker)
        deliver(owner, effect_ref, :cancelled, event_builder)
    after
      timeout ->
        terminate_worker(supervisor, worker)
        deliver(owner, effect_ref, :timed_out, event_builder)
    end
  end

  defp execute(work) do
    {:returned, work.()}
  catch
    kind, reason -> {:crashed, kind, reason, __STACKTRACE__}
  end

  defp deliver(owner, effect_ref, outcome, event_builder) do
    if Process.alive?(owner) do
      {event, payload} = event_builder.(effect_ref, outcome)
      GenServer.cast(owner, {event, payload})

      # Keep the registry key until the terminal cast has been consumed. A call
      # from this coordinator cannot overtake its own cast.
      try do
        GenServer.call(owner, :state, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp terminate_worker(supervisor, worker) do
    case Task.Supervisor.terminate_child(supervisor, worker) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
