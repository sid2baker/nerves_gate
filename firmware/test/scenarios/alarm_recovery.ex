defmodule NervesGate.Scenarios.AlarmRecovery do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.{AlarmChecks, Alarms, RecoveryChecks, ScenarioHelpers}
  alias NervesGate.TestQemu, as: Qemu

  def spec,
    do: %{
      name:
        "Alarmist debounces availability, preserves timers on registration and clears after owner restart"
    }

  def run(%{device: vm}) do
    thresholds(vm)
    before = RecoveryChecks.baseline(vm)
    Qemu.await(vm, "Internet healthy before alarm recovery", &ScenarioHelpers.internet?/1, 60_000)
    raw = {Alarms, NervesGate.Network, :internet_unavailable}
    managed = {Alarms.Warning, NervesGate.Network, :internet_unavailable}
    await_state(vm, managed, :clear)

    assert :ok = Qemu.network(vm, %{cables: %{lan1: false}})
    await_state(vm, raw, :set)
    await_state(vm, managed, :set)
    pid = RecoveryChecks.restart_worker(vm, NervesGate.Network)
    RecoveryChecks.event(vm, :alarm_owner_restarted, %{owner: NervesGate.Network, pid: pid})

    # Restarting the producer must not clear a still-real fault or duplicate rules.
    await_state(vm, raw, :set)
    await_state(vm, managed, :set)
    rules = :erpc.call(vm.node, Alarmist, :managed_alarm_ids, [], 5_000)
    assert Enum.count(rules, &(&1 == managed)) == 1

    assert :ok = Qemu.network(vm, %{cables: %{lan1: true}})

    Qemu.await(
      vm,
      "Internet restored after alarm owner restart",
      &ScenarioHelpers.internet?/1,
      60_000
    )

    await_state(vm, raw, :clear)
    await_state(vm, managed, :clear)
    RecoveryChecks.await_recovery(vm, before, NervesGate.Network)
  end

  defp thresholds(vm) do
    raw = {Alarms, AlarmChecks, :internet_unavailable}
    managed = {Alarms.Warning, AlarmChecks, :internet_unavailable}

    # These pulses test Alarmist's own clock, not cable/DHCP detection latency.
    short =
      pulse(vm, :internet_unavailable, [{0, true}, {500, false}, {750, true}, {1_250, false}])

    assert states(short, raw) == [:set, :clear, :set, :clear]
    refute Enum.any?(short, &(&1.id == managed and &1.state == :set))

    sustained =
      pulse(vm, :internet_unavailable, [
        {0, true},
        {1_000, :register},
        {1_250, nil},
        {2_750, false}
      ])

    raised = event!(sustained, managed, :set)
    source = event!(sustained, raw, :set)
    cleared = event!(sustained, managed, :clear)
    source_clear = event!(sustained, raw, :clear)
    assert raised.level == :warning
    assert states(sustained, raw) == [:set, :clear]
    assert states(sustained, managed) == [:set, :clear]
    # Re-registering or reporting unknown must neither reset the timer nor clear.
    assert (raised.at - source.at) in 2_000..2_700
    assert (cleared.at - source_clear.at) in 0..1_000

    for fault <- [:network_restore_failed, :led_restore_failed, :recovery_failed] do
      critical_id = {Alarms, AlarmChecks, fault}
      critical = pulse(vm, fault, [{0, true}, {500, false}])
      assert %{level: :error} = raised = event!(critical, critical_id, :set)
      started = event!(critical, :probe_start, :start)
      assert (raised.at - started.at) in 0..1_000
      assert states(critical, critical_id) == [:set, :clear]
      refute Enum.any?(critical, &match?({Alarms.Warning, _, _}, &1.id))
    end
  end

  defp pulse(vm, fault, actions) do
    events = AlarmChecks.pulse(vm, fault, actions)
    RecoveryChecks.event(vm, :alarm_probe, %{fault: fault, actions: actions, events: events})
    events
  end

  defp states(events, id), do: for(event <- events, event.id == id, do: event.state)

  defp event!(events, id, state) do
    event = Enum.find(events, &(&1.id == id and &1.state == state))
    assert event, "Missing #{inspect({id, state})} in #{inspect(events)}"
    event
  end

  defp await_state(vm, id, state) do
    Qemu.await(vm, "Alarm #{inspect(id)} becomes #{state}", fn _ ->
      :erpc.call(vm.node, Alarmist, :alarm_state, [id], 2_000) == state
    end)
  end
end
