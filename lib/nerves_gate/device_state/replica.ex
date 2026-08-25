defmodule NervesGate.DeviceState.Replica do
  @moduledoc """
  Maintains one independently versioned remote DeviceState snapshot.

  A boot-ID change, malformed event, or revision gap discards incremental
  synchronization and requests a fresh atomic snapshot. Events are never
  buffered or replayed.
  """

  alias NervesGate.DeviceState.Server
  alias NervesGate.DeviceState.State
  alias NervesGate.FSM.Diagnostics

  @max_retry 30_000

  @fsm """
  [*] --> disconnected : boot
  disconnected --> disconnected : retry_timer_fired
  disconnected --> syncing : retry_timer_fired
  syncing --> synced : retry_timer_fired
  syncing --> backoff : retry_timer_fired
  syncing --> disconnected : retry_timer_fired
  synced --> synced : retry_timer_fired
  synced --> syncing : retry_timer_fired
  synced --> disconnected : retry_timer_fired
  synced --> synced : device_state_event_received
  synced --> syncing : device_state_event_received
  backoff --> backoff : retry_timer_fired
  backoff --> syncing : retry_timer_fired
  backoff --> disconnected : retry_timer_fired
  disconnected --> [*] : terminate
  """

  use NervesGate.FSM, fsm: @fsm, timer: 1_000

  @spec new(node(), keyword()) :: map()
  def new(remote_node, options \\ []) do
    Diagnostics.new(%{
      desired: %{node: remote_node},
      observed: nil,
      node: remote_node,
      connected?: Keyword.get(options, :connected?, fn node -> node in Node.list(:connected) end),
      state: nil,
      boot_id: nil,
      revision: 0,
      subscribe: Keyword.get(options, :subscribe, &remote_subscribe/2),
      retry_delay: Keyword.get(options, :retry_delay, 1_000),
      last_seen_at: nil,
      publisher: Keyword.get(options, :publisher, &publish/2)
    })
  end

  @spec replica(GenServer.server()) :: map() | nil
  def replica(server) do
    case Diagnostics.state(server) do
      %Finitomata.State{current: lifecycle, payload: %{state: %State{} = state} = payload} ->
        %{
          state: state,
          node: payload.node,
          boot_id: payload.boot_id,
          revision: payload.revision,
          connected: lifecycle == :synced,
          last_seen_at: payload.last_seen_at
        }

      _unavailable ->
        nil
    end
  end

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server), do: server |> Diagnostics.state() |> Diagnostics.view()

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, payload),
    do: finish(:*, :boot, :disconnected, payload, blocked_by: :node)

  def on_transition(:disconnected, :retry_timer_fired, _event_payload, payload) do
    if connected_node?(payload),
      do: finish(:disconnected, :retry_timer_fired, :syncing, payload, blocked_by: nil),
      else: finish(:disconnected, :retry_timer_fired, :disconnected, payload, blocked_by: :node)
  end

  def on_transition(:syncing, :retry_timer_fired, _event_payload, payload) do
    if connected_node?(payload),
      do: synchronize(payload),
      else: finish(:syncing, :retry_timer_fired, :disconnected, payload, blocked_by: :node)
  end

  def on_transition(:synced, :retry_timer_fired, _event_payload, payload) do
    if connected_node?(payload),
      do: finish(:synced, :retry_timer_fired, :synced, payload),
      else:
        finish(:synced, :retry_timer_fired, :disconnected, publish_replica(payload),
          blocked_by: :node
        )
  end

  def on_transition(:backoff, :retry_timer_fired, _event_payload, payload) do
    cond do
      not connected_node?(payload) ->
        finish(:backoff, :retry_timer_fired, :disconnected, payload, blocked_by: :node)

      retry_due?(payload) ->
        finish(:backoff, :retry_timer_fired, :syncing, payload, blocked_by: nil)

      true ->
        finish(:backoff, :retry_timer_fired, :backoff, payload)
    end
  end

  def on_transition(:synced, :device_state_event_received, envelope, payload) do
    case apply_remote(payload, envelope) do
      {:ok, payload} ->
        finish(:synced, :device_state_event_received, :synced, publish_replica(payload))

      :duplicate ->
        finish(:synced, :device_state_event_received, :synced, payload)

      :resync ->
        finish(:synced, :device_state_event_received, :syncing, payload, reason: :revision_gap)
    end
  end

  @impl Finitomata
  def on_timer(_state, %Finitomata.State{payload: payload}),
    do: {:transition, :retry_timer_fired, payload}

  defp synchronize(payload) do
    case payload.subscribe.(payload.node, self()) do
      {:ok, %{boot_id: boot_id, revision: revision, state: %State{} = state}} ->
        payload = %{
          payload
          | state: state,
            boot_id: boot_id,
            revision: revision,
            last_seen_at: now_datetime(),
            last_error: nil
        }

        finish(:syncing, :retry_timer_fired, :synced, publish_replica(payload),
          attempt: 0,
          retry_at: nil
        )

      {:error, reason} ->
        backoff(payload, {:subscribe_failed, public_error(reason)})

      _invalid ->
        backoff(payload, :invalid_snapshot)
    end
  end

  defp apply_remote(payload, envelope) do
    cond do
      envelope.boot_id != payload.boot_id ->
        :resync

      envelope.revision <= payload.revision ->
        :duplicate

      envelope.revision != payload.revision + 1 ->
        :resync

      true ->
        case State.apply_event(payload.state, envelope.event) do
          {:ok, state} ->
            {:ok,
             %{
               payload
               | state: state,
                 revision: envelope.revision,
                 last_seen_at: now_datetime()
             }}

          :error ->
            :resync
        end
    end
  end

  defp backoff(payload, error) do
    attempt = payload.attempt + 1
    wait = min(payload.retry_delay * max(attempt, 1), @max_retry)

    finish(:syncing, :retry_timer_fired, :backoff, payload,
      reason: error,
      error: error,
      attempt: attempt,
      retry_at: now() + wait
    )
  end

  defp publish_replica(%{state: %State{} = state} = payload) do
    replica = replica_from_payload(payload)
    payload.publisher.(state.device.device_id, replica)
    %{payload | observed: Map.drop(replica, [:state])}
  end

  defp replica_from_payload(payload) do
    %{
      state: payload.state,
      node: payload.node,
      boot_id: payload.boot_id,
      revision: payload.revision,
      connected: connected_node?(payload),
      last_seen_at: payload.last_seen_at
    }
  end

  defp finish(from, event, to, payload, options \\ []) do
    {:ok, to, Diagnostics.record(payload, from, event, to, options)}
  end

  defp connected_node?(payload), do: payload.connected?.(payload.node)
  defp retry_due?(%{retry_at: nil}), do: true
  defp retry_due?(payload), do: now() >= payload.retry_at
  defp now, do: System.monotonic_time(:millisecond)
  defp now_datetime, do: DateTime.utc_now() |> DateTime.truncate(:millisecond)
  defp public_error(reason) when is_atom(reason), do: reason
  defp public_error(_reason), do: :remote_state_unavailable

  defp remote_subscribe(node, client) do
    Server.subscribe({:finitomata, client}, {Server, node})
  catch
    :exit, reason -> {:error, reason}
  end

  defp publish(device_id, replica) do
    Phoenix.PubSub.local_broadcast(
      NervesGate.PubSub,
      "device_state",
      {:replica_changed, device_id, replica}
    )
  end
end
