defmodule NervesGate.FSM.Diagnostics do
  @moduledoc """
  Queries and the one-shot request boundary for the remaining workflow FSMs.

  Most owner commands acknowledge intent immediately. Guarded configuration
  steps and firmware commands additionally return their committed outcome
  through a short-lived relay. There is no state polling.
  """

  alias Finitomata.State

  @base %{
    desired: nil,
    observed: nil,
    blocked_by: nil,
    last_event: nil,
    last_error: nil,
    attempt: 0,
    retry_at: nil
  }

  @spec new(map()) :: map()
  def new(extra \\ %{}) when is_map(extra), do: Map.merge(@base, extra)

  @spec record(map(), atom(), atom(), atom(), keyword()) :: map()
  def record(payload, _from, event, _to, options \\ []) do
    Map.merge(payload, %{
      last_event: event,
      last_error: Keyword.get(options, :error, payload.last_error),
      blocked_by: Keyword.get(options, :blocked_by, payload.blocked_by),
      attempt: Keyword.get(options, :attempt, payload.attempt),
      retry_at: Keyword.get(options, :retry_at, payload.retry_at)
    })
  end

  @spec view(State.t() | nil) :: map() | nil
  def view(nil), do: nil

  def view(%State{current: current, history: history, payload: payload}) do
    %{
      state: current,
      desired: Map.get(payload, :desired),
      observed: Map.get(payload, :observed),
      blocked_by: Map.get(payload, :blocked_by),
      last_event: Map.get(payload, :last_event),
      last_error: Map.get(payload, :last_error),
      attempt: Map.get(payload, :attempt, 0),
      retry_at: Map.get(payload, :retry_at),
      history: history
    }
  end

  @spec state(GenServer.server(), timeout()) :: State.t() | nil
  def state(server, timeout \\ 5_000) do
    GenServer.call(server, :state, timeout)
  catch
    :exit, _reason -> nil
  end

  @spec request(GenServer.server(), atom(), map(), timeout()) :: term()
  def request(server, event, payload, timeout) do
    caller = self()
    request_ref = make_ref()
    relay = spawn(fn -> relay_reply(caller, request_ref, timeout) end)

    with %State{} <- state(server, timeout),
         true <- GenServer.call(server, {:responds?, event}, timeout),
         pid when is_pid(pid) <- GenServer.whereis(server) do
      monitor = Process.monitor(pid)
      GenServer.cast(server, {event, Map.put(payload, :id, relay)})
      await_reply(request_ref, relay, pid, monitor, timeout)
    else
      %State{current: current} ->
        send(relay, :cancel)
        {:error, {:invalid_transition, current, event}}

      false ->
        send(relay, :cancel)
        {:error, {:invalid_transition, state_name(server), event}}

      nil ->
        send(relay, :cancel)
        {:error, :owner_unavailable}
    end
  end

  @spec deliver_reply(term()) :: :ok
  def deliver_reply(%{reply: {relay, result}}) when is_pid(relay) do
    send(relay, {:complete, result})
    :ok
  end

  def deliver_reply(_payload), do: :ok

  @spec transition(GenServer.server(), atom(), term(), timeout()) ::
          {:ok, State.t()} | {:error, {:invalid_transition, atom() | nil, atom()}}
  def transition(server, event, event_payload \\ nil, timeout \\ 5_000) do
    case state(server, timeout) do
      %State{current: current} ->
        if GenServer.call(server, {:responds?, event}, timeout) do
          GenServer.cast(server, {event, event_payload})
          {:ok, GenServer.call(server, :state, timeout)}
        else
          {:error, {:invalid_transition, current, event}}
        end

      nil ->
        {:error, {:invalid_transition, nil, event}}
    end
  end

  defp await_reply(request_ref, relay, owner, monitor, timeout) do
    receive do
      {:fsm_request_completed, ^request_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        send(relay, :cancel)
        {:error, :owner_unavailable}
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        send(relay, :cancel)
        {:error, :command_timeout}
    end
  end

  defp relay_reply(caller, request_ref, timeout) do
    receive do
      {:complete, result} -> send(caller, {:fsm_request_completed, request_ref, result})
      :cancel -> :ok
    after
      timeout -> :ok
    end
  end

  defp state_name(server) do
    case state(server) do
      %State{current: current} -> current
      nil -> nil
    end
  end
end
