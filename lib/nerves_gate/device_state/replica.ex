defmodule NervesGate.DeviceState.Replica do
  @moduledoc """
  Reduces one remote gateway's ordered DeviceState stream into a local copy.

  Joining atomically installs a snapshot before the source pushes revisioned
  events. Source heartbeats maintain a short liveness lease without polling
  snapshots. A lease expiry preserves the last-known state and immediately
  publishes it as disconnected. A boot-ID change, malformed event, or revision
  gap discards incremental synchronization and requests a fresh snapshot;
  events are never buffered or replayed.
  """

  alias NervesGate.DeviceState.Server
  alias NervesGate.DeviceState.State
  alias NervesGate.FSM.Diagnostics

  @max_retry 30_000
  @lease_timeout 2_500

  @fsm """
  [*] --> disconnected : boot
  disconnected --> disconnected : retry_timer_fired
  disconnected --> syncing : retry_timer_fired
  disconnected --> syncing : device_state_heartbeat_received
  syncing --> synced : retry_timer_fired
  syncing --> backoff : retry_timer_fired
  syncing --> disconnected : retry_timer_fired
  syncing --> syncing : device_state_heartbeat_received
  synced --> synced : retry_timer_fired
  synced --> syncing : retry_timer_fired
  synced --> disconnected : retry_timer_fired
  synced --> synced : device_state_event_received
  synced --> syncing : device_state_event_received
  synced --> synced : device_state_heartbeat_received
  synced --> syncing : device_state_heartbeat_received
  backoff --> backoff : retry_timer_fired
  backoff --> syncing : retry_timer_fired
  backoff --> disconnected : retry_timer_fired
  backoff --> syncing : device_state_heartbeat_received
  disconnected --> [*] : terminate
  """

  use NervesGate.FSM, fsm: @fsm, timer: 1_000, supervised: false

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
      lease_timeout: Keyword.get(options, :lease_timeout, @lease_timeout),
      clock: Keyword.get(options, :clock, fn -> System.monotonic_time(:millisecond) end),
      last_received_at: nil,
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
    cond do
      not connected_node?(payload) ->
        finish(
          :synced,
          :retry_timer_fired,
          :disconnected,
          publish_replica(payload, false),
          blocked_by: :node
        )

      lease_expired?(payload) ->
        finish(
          :synced,
          :retry_timer_fired,
          :disconnected,
          publish_replica(payload, false),
          blocked_by: :heartbeat,
          error: :heartbeat_timeout
        )

      true ->
        finish(:synced, :retry_timer_fired, :synced, payload)
    end
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
        finish(:synced, :device_state_event_received, :synced, publish_replica(payload, true))

      {:duplicate, payload} ->
        finish(:synced, :device_state_event_received, :synced, payload)

      :resync ->
        finish(
          :synced,
          :device_state_event_received,
          :syncing,
          publish_replica(payload, false),
          reason: :revision_gap
        )
    end
  end

  def on_transition(:synced, :device_state_heartbeat_received, envelope, payload) do
    case accept_heartbeat(payload, envelope) do
      {:ok, payload} ->
        finish(:synced, :device_state_heartbeat_received, :synced, payload)

      {:resync, reason, payload} ->
        finish(
          :synced,
          :device_state_heartbeat_received,
          :syncing,
          publish_replica(payload, false),
          reason: reason
        )
    end
  end

  def on_transition(state, :device_state_heartbeat_received, envelope, payload)
      when state in [:disconnected, :syncing, :backoff] do
    payload =
      if heartbeat_from_remote?(payload, envelope), do: touch_received(payload), else: payload

    finish(state, :device_state_heartbeat_received, :syncing, payload,
      blocked_by: nil,
      retry_at: nil
    )
  end

  @impl Finitomata
  def on_timer(_state, %Finitomata.State{payload: payload}),
    do: {:transition, :retry_timer_fired, payload}

  defp synchronize(payload) do
    case payload.subscribe.(payload.node, self()) do
      {:ok, %{boot_id: boot_id, revision: revision, state: %State{} = state}} ->
        payload = install_snapshot(payload, boot_id, revision, state)

        finish(:syncing, :retry_timer_fired, :synced, publish_replica(payload, true),
          attempt: 0,
          retry_at: nil
        )

      {:error, reason} ->
        backoff(payload, {:subscribe_failed, public_error(reason)})

      _invalid ->
        backoff(payload, :invalid_snapshot)
    end
  end

  defp install_snapshot(payload, boot_id, revision, state) do
    payload
    |> Map.merge(%{
      state: state,
      boot_id: boot_id,
      revision: revision,
      last_error: nil
    })
    |> touch_received()
  end

  defp apply_remote(payload, envelope) do
    cond do
      envelope.node != payload.node ->
        :resync

      envelope.boot_id != payload.boot_id ->
        :resync

      envelope.revision < payload.revision ->
        {:duplicate, touch_received(payload)}

      envelope.revision == payload.revision ->
        {:duplicate, touch_received(payload)}

      envelope.revision != payload.revision + 1 ->
        :resync

      true ->
        case State.apply_event(payload.state, envelope.event) do
          {:ok, state} ->
            {:ok,
             payload
             |> Map.put(:state, state)
             |> Map.put(:revision, envelope.revision)
             |> touch_received()}

          :error ->
            :resync
        end
    end
  end

  defp accept_heartbeat(payload, envelope) do
    payload =
      if heartbeat_from_remote?(payload, envelope), do: touch_received(payload), else: payload

    cond do
      not heartbeat_from_remote?(payload, envelope) ->
        {:resync, :invalid_heartbeat, payload}

      envelope.boot_id != payload.boot_id ->
        {:resync, :boot_changed, payload}

      envelope.revision > payload.revision ->
        {:resync, :revision_gap, payload}

      true ->
        {:ok, payload}
    end
  end

  defp heartbeat_from_remote?(payload, %{node: node, boot_id: boot_id, revision: revision}) do
    node == payload.node and is_binary(boot_id) and is_integer(revision) and revision >= 0
  end

  defp heartbeat_from_remote?(_payload, _envelope), do: false

  defp touch_received(payload) do
    %{
      payload
      | last_received_at: now(payload),
        last_seen_at: now_datetime()
    }
  end

  defp backoff(payload, error) do
    attempt = payload.attempt + 1
    wait = min(payload.retry_delay * max(attempt, 1), @max_retry)

    finish(:syncing, :retry_timer_fired, :backoff, payload,
      reason: error,
      error: error,
      attempt: attempt,
      retry_at: now(payload) + wait
    )
  end

  defp publish_replica(%{state: %State{} = state} = payload, connected) do
    replica = replica_from_payload(payload, connected)
    payload.publisher.(state.device.device_id, replica)
    %{payload | observed: Map.drop(replica, [:state])}
  end

  defp replica_from_payload(payload, connected) do
    %{
      state: payload.state,
      node: payload.node,
      boot_id: payload.boot_id,
      revision: payload.revision,
      connected: connected,
      last_seen_at: payload.last_seen_at
    }
  end

  defp finish(from, event, to, payload, options \\ []) do
    {:ok, to, Diagnostics.record(payload, from, event, to, options)}
  end

  defp connected_node?(payload), do: payload.connected?.(payload.node)
  defp lease_expired?(%{last_received_at: nil}), do: true

  defp lease_expired?(payload),
    do: now(payload) - payload.last_received_at >= payload.lease_timeout

  defp retry_due?(%{retry_at: nil}), do: true
  defp retry_due?(payload), do: now(payload) >= payload.retry_at
  defp now(payload), do: payload.clock.()
  defp now_datetime, do: DateTime.utc_now() |> DateTime.truncate(:millisecond)
  defp public_error(reason) when is_atom(reason), do: reason
  defp public_error(_reason), do: :remote_state_unavailable

  defp remote_subscribe(node, client) do
    Server.subscribe({:finitomata, client}, {Server, node}, 1_000)
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
