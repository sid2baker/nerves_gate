defmodule NervesGate.DeviceState.ReplicaTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.{Replica, State}
  alias NervesGate.FSM.Diagnostics

  setup do
    state = state("Remote")

    {:ok, snapshot} =
      Agent.start_link(fn -> %{boot_id: "boot-a", revision: 1, state: state} end)

    {:ok, connected} = Agent.start_link(fn -> true end)
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, subscriptions} = Agent.start_link(fn -> 0 end)
    {:ok, publications} = Agent.start_link(fn -> [] end)

    subscribe = fn _node, _client ->
      Agent.update(subscriptions, &(&1 + 1))
      {:ok, Agent.get(snapshot, & &1)}
    end

    name = String.to_atom("replica_machine_#{System.unique_integer([:positive])}")

    payload =
      Replica.new(:"remote@100.64.0.11",
        subscribe: subscribe,
        connected?: fn _ -> Agent.get(connected, & &1) end,
        publisher: fn id, replica -> Agent.update(publications, &[{id, replica} | &1]) end,
        retry_delay: 1,
        lease_timeout: 2_500,
        clock: fn -> Agent.get(clock, & &1) end
      )

    {:ok, machine} = Replica.start_link(payload: payload, name: name)

    %{
      machine: machine,
      snapshot: snapshot,
      connected: connected,
      clock: clock,
      subscriptions: subscriptions,
      publications: publications,
      state: state
    }
  end

  test "snapshot followed by ordered events remains canonical", context do
    synchronize(context.machine)
    assert Replica.replica(context.machine).revision == 1

    event = {:state_reported, :device, device("Updated")}
    transition(context.machine, :device_state_event_received, envelope("boot-a", 2, event))

    assert Replica.replica(context.machine).revision == 2
    assert Replica.replica(context.machine).state.device.name == "Updated"

    transition(context.machine, :device_state_event_received, envelope("boot-a", 2, event))
    assert Replica.replica(context.machine).revision == 2
  end

  test "revision gaps discard incremental state and request a fresh snapshot", context do
    synchronize(context.machine)

    transition(
      context.machine,
      :device_state_event_received,
      envelope("boot-a", 4, {:state_reported, :device, device("Four")})
    )

    assert Replica.diagnostics(context.machine).state == :syncing
    refute latest_publication(context).connected

    Agent.update(context.snapshot, fn _ ->
      %{boot_id: "boot-a", revision: 4, state: state("Four")}
    end)

    transition(context.machine, :retry_timer_fired)

    assert Replica.diagnostics(context.machine).state == :synced
    assert Replica.replica(context.machine).revision == 4
    assert Replica.replica(context.machine).state.device.name == "Four"
  end

  test "heartbeats keep an idle replica connected without polling snapshots", context do
    synchronize(context.machine)
    assert Agent.get(context.subscriptions, & &1) == 1

    advance(context.clock, 2_000)
    transition(context.machine, :device_state_heartbeat_received, heartbeat("boot-a", 1))
    advance(context.clock, 2_000)
    transition(context.machine, :retry_timer_fired)

    assert Replica.replica(context.machine).connected
    assert Agent.get(context.subscriptions, & &1) == 1
  end

  test "heartbeat boot changes force a fresh atomic snapshot", context do
    synchronize(context.machine)

    Agent.update(context.snapshot, fn _ ->
      %{boot_id: "boot-b", revision: 1, state: state("Rebooted")}
    end)

    transition(context.machine, :device_state_heartbeat_received, heartbeat("boot-b", 1))

    assert Replica.diagnostics(context.machine).state == :syncing
    refute latest_publication(context).connected

    transition(context.machine, :retry_timer_fired)

    assert Replica.replica(context.machine).boot_id == "boot-b"
    assert Replica.replica(context.machine).state.device.name == "Rebooted"
  end

  test "a missed heartbeat lease immediately publishes last-known state as disconnected",
       context do
    synchronize(context.machine)
    advance(context.clock, 2_500)

    transition(context.machine, :retry_timer_fired)

    replica = Replica.replica(context.machine)
    refute replica.connected
    assert replica.state == context.state
    assert Replica.diagnostics(context.machine).blocked_by == :heartbeat

    published = latest_publication(context)
    refute published.connected
    assert published.state == context.state
  end

  test "node loss keeps last-known state and marks transport disconnected", context do
    synchronize(context.machine)
    Agent.update(context.connected, fn _ -> false end)
    transition(context.machine, :retry_timer_fired)

    replica = Replica.replica(context.machine)
    refute replica.connected
    assert replica.state == context.state
    assert Replica.diagnostics(context.machine).blocked_by == :node
    refute latest_publication(context).connected
  end

  defp synchronize(machine) do
    transition(machine, :retry_timer_fired)
    transition(machine, :retry_timer_fired)
  end

  defp transition(machine, event, payload \\ nil) do
    assert {:ok, _state} = Diagnostics.transition(machine, event, payload)
  end

  defp envelope(boot_id, revision, event) do
    %{
      node: :"remote@100.64.0.11",
      boot_id: boot_id,
      revision: revision,
      event: event
    }
  end

  defp heartbeat(boot_id, revision) do
    %{node: :"remote@100.64.0.11", boot_id: boot_id, revision: revision}
  end

  defp latest_publication(context) do
    context.publications
    |> Agent.get(& &1)
    |> hd()
    |> elem(1)
  end

  defp advance(clock, milliseconds), do: Agent.update(clock, &(&1 + milliseconds))

  defp state(name) do
    {:ok, state} = State.apply_event(State.new(), {:state_reported, :device, device(name)})
    state
  end

  defp device(name),
    do: %{device_id: "gate-a", name: name, firmware_version: "1.0.0"}
end
