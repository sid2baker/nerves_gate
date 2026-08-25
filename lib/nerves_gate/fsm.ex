defmodule NervesGate.FSM do
  @moduledoc false

  defmacro __using__(options) do
    fsm = Keyword.fetch!(options, :fsm)
    timer = Keyword.fetch!(options, :timer)

    quote do
      use Finitomata,
        fsm: unquote(fsm),
        syntax: NervesGate.FSM.Mermaid,
        telemetria_levels: :none,
        timer: unquote(timer),
        listener: NervesGate.FSM.Listener,
        impl_for: :none

      @spec graph() :: String.t()
      def graph, do: unquote(fsm)
    end
  end
end

defmodule NervesGate.FSM.Listener do
  @moduledoc "Dispatches post-commit lifecycle callbacks to each owning FSM module."
  @behaviour Finitomata.Listener

  @impl true
  def after_transition(_name, state, %{owner: owner} = payload) when is_atom(owner) do
    if function_exported?(owner, :after_transition, 2),
      do: owner.after_transition(state, payload),
      else: :ok
  end

  def after_transition(_name, _state, _payload), do: :ok
end

defmodule NervesGate.FSM.Diagnostics do
  @moduledoc "Minimal lifecycle diagnostics and direct-machine transition helpers."

  alias Finitomata.State
  alias NervesGate.FSM.TransitionHistory

  @base %{
    desired: nil,
    observed: nil,
    blocked_by: nil,
    last_event: nil,
    last_error: nil,
    attempt: 0,
    retry_at: nil,
    history: []
  }

  @spec new(map()) :: map()
  def new(extra \\ %{}) when is_map(extra), do: Map.merge(@base, extra)

  @spec record(map(), atom(), atom(), atom(), keyword()) :: map()
  def record(payload, from, event, to, options \\ []) do
    reason = Keyword.get(options, :reason)

    payload
    |> Map.merge(%{
      last_event: event,
      last_error: Keyword.get(options, :error, payload.last_error),
      blocked_by: Keyword.get(options, :blocked_by, payload.blocked_by),
      attempt: Keyword.get(options, :attempt, payload.attempt),
      retry_at: Keyword.get(options, :retry_at, payload.retry_at)
    })
    |> Map.update!(:history, &TransitionHistory.record(&1, from, event, to, reason))
  end

  @spec view(State.t() | nil) :: map() | nil
  def view(nil), do: nil

  def view(%State{current: current, payload: payload}) do
    %{
      state: current,
      desired: Map.get(payload, :desired),
      observed: Map.get(payload, :observed),
      blocked_by: Map.get(payload, :blocked_by),
      last_event: Map.get(payload, :last_event),
      last_error: Map.get(payload, :last_error),
      attempt: Map.get(payload, :attempt, 0),
      retry_at: Map.get(payload, :retry_at),
      history: Map.get(payload, :history, [])
    }
  end

  @spec state(GenServer.server(), timeout()) :: State.t() | nil
  def state(server, timeout \\ 5_000) do
    GenServer.call(server, :state, timeout)
  catch
    :exit, _reason -> nil
  end

  @spec command(GenServer.server(), atom(), map(), timeout()) :: term()
  def command(server, event, payload, timeout) do
    id = make_ref()
    payload = Map.put(payload, :id, id)
    deadline = System.monotonic_time(:millisecond) + timeout

    case transition(server, event, payload, timeout) do
      {:ok, %State{payload: %{last_result: {^id, result}}}} -> result
      {:ok, _state} -> await_result(server, id, deadline)
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_result(server, id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :command_timeout}
    else
      case state(server, min(remaining, 1_000)) do
        %State{payload: %{last_result: {^id, result}}} ->
          result

        %State{} ->
          Process.sleep(min(5, remaining))
          await_result(server, id, deadline)

        nil ->
          {:error, :owner_unavailable}
      end
    end
  end

  @spec transition(GenServer.server(), atom(), term(), timeout()) ::
          {:ok, State.t()} | {:error, {:invalid_transition, atom() | nil, atom()}}
  def transition(server, event, event_payload \\ nil, timeout \\ 5_000) do
    case state(server, timeout) do
      %State{current: current} ->
        if GenServer.call(server, {:responds?, event}) do
          GenServer.cast(server, {event, event_payload})
          {:ok, GenServer.call(server, :state, timeout)}
        else
          {:error, {:invalid_transition, current, event}}
        end

      nil ->
        {:error, {:invalid_transition, nil, event}}
    end
  end
end

defmodule NervesGate.FSM.Retry do
  @moduledoc false

  @spec due?(integer() | nil) :: boolean()
  def due?(nil), do: true
  def due?(retry_at), do: now() >= retry_at

  @spec now() :: integer()
  def now, do: System.monotonic_time(:millisecond)

  @spec public_error(term()) :: atom()
  def public_error(reason) when is_atom(reason), do: reason
  def public_error(_reason), do: :operation_failed

  @spec next(pos_integer(), pos_integer()) :: {pos_integer(), pos_integer()}
  def next(current, maximum) when current > 0 and maximum >= current do
    upper = min(maximum, current * 2)
    jittered = current + :rand.uniform(max(1, upper - current)) - 1
    {jittered, upper}
  end
end

defmodule NervesGate.FSM.TransitionHistory do
  @moduledoc "Bounded, diagnostic transition history shared by lifecycle machines."

  @default_limit 30

  @type entry :: %{
          from: atom(),
          event: atom(),
          to: atom(),
          at: integer(),
          reason: term()
        }

  @spec record([entry()], atom(), atom(), atom(), term(), pos_integer()) :: [entry()]
  def record(history, from, event, to, reason \\ nil, limit \\ @default_limit) do
    entry = %{
      from: from,
      event: event,
      to: to,
      at: System.system_time(:millisecond),
      reason: reason
    }

    [entry | history]
    |> Enum.take(limit)
  end
end

defmodule NervesGate.FSM.Mermaid do
  @moduledoc false

  @behaviour Finitomata.Parser

  @impl Finitomata.Parser
  defdelegate parse(source), to: Finitomata.PlantUML

  defdelegate parse(source, environment), to: Finitomata.PlantUML

  @impl Finitomata.Parser
  defdelegate validate(transitions), to: Finitomata.PlantUML

  defdelegate validate(transitions, environment), to: Finitomata.PlantUML

  @impl Finitomata.Parser
  def lint(source), do: "stateDiagram-v2\n" <> String.trim(source)
end

defmodule NervesGate.FSM.Effect do
  @moduledoc """
  Supervised lifecycle wrapper for one private asynchronous runtime effect.

  Correlation references and worker outcomes remain private FSM inputs. The
  helper supplies supervision, owner-epoch monitoring, timeout, cancellation,
  and one terminal transition attempt; resource serialization remains the
  responsibility of the owning FSM.
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
        outcome = {:crashed, :exit, reason, []}
        deliver(owner, effect_ref, outcome, event_builder)

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

      # A call from the same coordinator cannot overtake its cast. Keeping the
      # Registry key until this returns prevents a same-ref relaunch while the
      # terminal event is queued behind commands from other senders.
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
