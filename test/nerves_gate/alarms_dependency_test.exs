defmodule NervesGate.AlarmsDependencyTest do
  use ExUnit.Case

  alias NervesGate.Alarms
  alias NervesGate.Cluster
  alias NervesGate.Commissioning
  alias NervesGate.Internet
  alias NervesGate.Settings
  alias NervesGate.Tailnet

  setup do
    ids = [
      Internet.Signal.Unavailable,
      Tailnet.Signal.Unavailable,
      Cluster.Signal.Enabled,
      Cluster.Signal.Unavailable,
      Commissioning.Alarm.Required,
      Settings.Signal.InternetChanging,
      Settings.Signal.TailnetChanging,
      Settings.Signal.ClusterChanging
    ]

    Enum.each(ids, &Alarms.clear/1)
    Enum.each(ids, fn id -> on_exit(fn -> Alarms.clear(id) end) end)
    wait_for(fn -> Enum.all?(ids, &(Alarmist.alarm_state(&1) != :set)) end)
    :ok
  end

  test "Internet failure is the only actionable connectivity alarm" do
    set(Cluster.Signal.Enabled)
    set(Cluster.Signal.Unavailable)
    set(Tailnet.Signal.Unavailable)
    set(Internet.Signal.Unavailable)

    wait_for(fn -> Alarmist.alarm_state(Internet.Alarm.Unavailable) == :set end)
    assert Alarmist.alarm_state(Tailnet.Alarm.Unavailable) != :set
    assert Alarmist.alarm_state(Cluster.Alarm.Unavailable) != :set
  end

  test "Tailnet failure is actionable only while Internet is healthy" do
    set(Cluster.Signal.Enabled)
    set(Cluster.Signal.Unavailable)
    set(Tailnet.Signal.Unavailable)
    Alarms.clear(Internet.Signal.Unavailable)

    wait_for(fn -> Alarmist.alarm_state(Tailnet.Alarm.Unavailable) == :set end)
    assert Alarmist.alarm_state(Internet.Alarm.Unavailable) != :set
    assert Alarmist.alarm_state(Cluster.Alarm.Unavailable) != :set
  end

  test "Tailnet debounce restarts when Internet returns" do
    set(Tailnet.Signal.Unavailable)
    Process.sleep(10)
    set(Internet.Signal.Unavailable)
    wait_for(fn -> Alarmist.alarm_state(Tailnet.Condition.ActionableUnavailable) != :set end)

    Alarms.clear(Internet.Signal.Unavailable)
    Process.sleep(10)
    assert Alarmist.alarm_state(Tailnet.Alarm.Unavailable) != :set
    wait_for(fn -> Alarmist.alarm_state(Tailnet.Alarm.Unavailable) == :set end)
  end

  test "an enabled broken cluster is actionable after Internet and Tailnet" do
    Alarms.clear(Internet.Signal.Unavailable)
    Alarms.clear(Tailnet.Signal.Unavailable)
    set(Cluster.Signal.Enabled)
    set(Cluster.Signal.Unavailable)

    wait_for(fn -> Alarmist.alarm_state(Cluster.Alarm.Unavailable) == :set end)
    assert Alarmist.alarm_state(Internet.Alarm.Unavailable) != :set
    assert Alarmist.alarm_state(Tailnet.Alarm.Unavailable) != :set
  end

  test "planned Internet changes inhibit expected dependency alarms" do
    Settings.Maintenance.begin(:internet)
    on_exit(&Settings.Maintenance.clear/0)
    set(Cluster.Signal.Enabled)
    set(Cluster.Signal.Unavailable)
    set(Tailnet.Signal.Unavailable)
    set(Internet.Signal.Unavailable)

    Process.sleep(40)
    assert Alarmist.alarm_state(Internet.Alarm.Unavailable) != :set
    assert Alarmist.alarm_state(Tailnet.Alarm.Unavailable) != :set
    assert Alarmist.alarm_state(Cluster.Alarm.Unavailable) != :set
  end

  test "subsystems do not feed expected maintenance transitions into alarm history" do
    Settings.Maintenance.begin(:internet)
    on_exit(&Settings.Maintenance.clear/0)

    Internet.Alarms.report(%{online: false})
    Tailnet.Alarms.report(%{online: false})
    Cluster.Alarms.report(true, true)
    Process.sleep(10)

    assert Alarmist.alarm_state(Internet.Signal.Unavailable) != :set
    assert Alarmist.alarm_state(Tailnet.Signal.Unavailable) != :set
    assert Alarmist.alarm_state(Cluster.Signal.Unavailable) != :set
  end

  test "singular mode suppresses cluster failure" do
    Alarms.clear(Internet.Signal.Unavailable)
    Alarms.clear(Tailnet.Signal.Unavailable)
    Alarms.clear(Cluster.Signal.Enabled)
    set(Cluster.Signal.Unavailable)

    Process.sleep(40)
    assert Alarmist.alarm_state(Cluster.Alarm.Unavailable) != :set
  end

  defp set(id), do: Alarms.set(id, id.description())

  defp wait_for(predicate, attempts \\ 100) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("alarm condition did not converge")

      true ->
        Process.sleep(5)
        wait_for(predicate, attempts - 1)
    end
  end
end
