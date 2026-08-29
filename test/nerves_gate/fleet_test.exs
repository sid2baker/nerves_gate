defmodule NervesGate.FleetTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.State
  alias NervesGate.Fleet

  @remote :"remote@100.64.0.11"

  setup do
    remote_state = state("Remote")

    {:ok, snapshot} =
      Agent.start_link(fn ->
        %{node: @remote, boot_id: "boot-a", revision: 1, state: remote_state, hydrated: false}
      end)

    {:ok, connected} = Agent.start_link(fn -> [@remote] end)
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, subscriptions} = Agent.start_link(fn -> 0 end)

    subscribe = fn _node, _client ->
      Agent.update(subscriptions, &(&1 + 1))
      {:ok, Agent.get(snapshot, & &1)}
    end

    {:ok, fleet} =
      Fleet.start_link(
        name: nil,
        boot_id: "fleet-a",
        connected_nodes: fn -> Agent.get(connected, & &1) end,
        subscribe_remote: subscribe,
        clock: fn -> Agent.get(clock, & &1) end,
        wall_clock: fn -> ~U[2026-01-01 00:00:00.000Z] end,
        retry_delay: 1,
        lease_timeout: 2_500,
        tick_interval: 60_000
      )

    {:ok, _snapshot} = Fleet.subscribe(self(), fleet)
    tick(fleet)
    assert_eventually(fn -> not is_nil(Fleet.replicas(fleet)["gate-a"]) end)

    %{
      fleet: fleet,
      snapshot: snapshot,
      connected: connected,
      clock: clock,
      subscriptions: subscriptions,
      state: remote_state
    }
  end

  test "one process reduces snapshots and ordered operations for every node", context do
    assert replica(context).revision == 1

    send(
      context.fleet,
      {:device_state_operation, @remote, "boot-a", 2, {:put, :device, device("Updated")}}
    )

    assert_eventually(fn -> replica(context).revision == 2 end)
    assert replica(context).state.device.name == "Updated"

    send(
      context.fleet,
      {:device_state_operation, @remote, "boot-a", 2, {:put, :device, device("Updated")}}
    )

    _state = :sys.get_state(context.fleet)
    assert replica(context).revision == 2
  end

  test "revision gaps publish disconnected state and atomically resubscribe", context do
    send(
      context.fleet,
      {:device_state_operation, @remote, "boot-a", 4, {:put, :device, device("Four")}}
    )

    assert_eventually(fn -> not replica(context).connected end)

    Agent.update(context.snapshot, fn _ ->
      %{node: @remote, boot_id: "boot-a", revision: 4, state: state("Four"), hydrated: false}
    end)

    tick(context.fleet)

    assert_eventually(fn -> replica(context).connected and replica(context).revision == 4 end)
    assert replica(context).state.device.name == "Four"
  end

  test "heartbeats renew the lease without polling snapshots", context do
    assert Agent.get(context.subscriptions, & &1) == 1

    advance(context.clock, 2_000)
    send(context.fleet, {:device_state_heartbeat, @remote, "boot-a", 1})
    _state = :sys.get_state(context.fleet)
    advance(context.clock, 2_000)
    tick(context.fleet)

    assert replica(context).connected
    assert Agent.get(context.subscriptions, & &1) == 1
  end

  test "heartbeat boot changes force a fresh snapshot", context do
    Agent.update(context.snapshot, fn _ ->
      %{node: @remote, boot_id: "boot-b", revision: 1, state: state("Rebooted"), hydrated: false}
    end)

    send(context.fleet, {:device_state_heartbeat, @remote, "boot-b", 1})
    assert_eventually(fn -> not replica(context).connected end)

    tick(context.fleet)

    assert_eventually(fn -> replica(context).boot_id == "boot-b" end)
    assert replica(context).state.device.name == "Rebooted"
  end

  test "a missed lease publishes last-known state as disconnected before resubscribing",
       context do
    drain_operations()
    advance(context.clock, 2_500)
    tick(context.fleet)

    assert_receive {:fleet_operation, "fleet-a", _revision,
                    {:put, "gate-a", %{connected: false, state: state}}}

    assert state == context.state
    assert_eventually(fn -> replica(context).connected end)
  end

  test "node loss preserves last-known state", context do
    Agent.update(context.connected, fn _ -> [] end)
    tick(context.fleet)

    remote = replica(context)
    refute remote.connected
    assert remote.state == context.state
  end

  defp drain_operations do
    receive do
      {:fleet_operation, _, _, _} -> drain_operations()
    after
      0 -> :ok
    end
  end

  defp tick(fleet) do
    send(fleet, :tick)
    _state = :sys.get_state(fleet)
    :ok
  end

  defp replica(context), do: Fleet.replicas(context.fleet)["gate-a"]
  defp advance(clock, milliseconds), do: Agent.update(clock, &(&1 + milliseconds))

  defp assert_eventually(predicate, attempts \\ 50) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not converge")

      true ->
        Process.sleep(10)
        assert_eventually(predicate, attempts - 1)
    end
  end

  defp state(name) do
    {:ok, state} = State.reduce(State.new(), {:put, :device, device(name)})
    state
  end

  defp device(name),
    do: %{device_id: "gate-a", name: name, firmware_version: "1.0.0"}
end
