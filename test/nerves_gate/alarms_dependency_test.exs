defmodule NervesGate.AlarmsDependencyTest do
  use ExUnit.Case

  alias NervesGate.Alarms
  alias NervesGate.Cluster
  alias NervesGate.Commissioning
  alias NervesGate.DeviceState
  alias NervesGate.Internet
  alias NervesGate.SSH
  alias NervesGate.Storage
  alias NervesGate.SubnetRouter
  alias NervesGate.Tailnet

  setup_all do
    runtime = Process.whereis(NervesGate.Alarms.Runtime)
    if runtime, do: :sys.suspend(runtime)

    on_exit(fn ->
      if runtime && Process.alive?(runtime), do: :sys.resume(runtime)
    end)

    :ok
  end

  setup do
    signals = [
      Storage.Signal.Failure,
      Commissioning.Signal.Required,
      Commissioning.Signal.AccessUnavailable,
      DeviceState.Signal.Changing,
      Internet.Signal.Unavailable,
      Internet.Signal.UnavailableSample,
      Tailnet.Signal.Unavailable,
      Cluster.Signal.Enabled,
      Cluster.Signal.Unavailable,
      SSH.Signal.Enabled,
      SSH.Signal.Unavailable,
      SubnetRouter.Signal.Unavailable
    ]

    Enum.each(signals, &Alarms.clear/1)

    signals
    |> List.delete(Internet.Signal.UnavailableSample)
    |> Enum.each(&initialize_clear/1)

    Enum.each(signals, fn id -> on_exit(fn -> Alarms.clear(id) end) end)

    wait_for(fn ->
      Enum.all?(signals ++ Alarms.public_ids(), &(Alarmist.alarm_state(&1) != :set))
    end)

    :ok
  end

  test "Internet is the sole root-cause alarm when every downstream layer fails" do
    set(Cluster.Signal.Enabled)
    set(Cluster.Signal.Unavailable)
    set(SSH.Signal.Enabled)
    set(SSH.Signal.Unavailable)
    set(SubnetRouter.Signal.Unavailable)
    set(Tailnet.Signal.Unavailable)
    set(Internet.Signal.Unavailable)

    wait_set(Internet.Alarm.Unavailable)
    refute_set(Tailnet.Alarm.Unavailable)
    refute_set(Cluster.Alarm.Unavailable)
    refute_set(SSH.Alarm.Unavailable)
    refute_set(SubnetRouter.Alarm.Unavailable)
  end

  test "Tailnet is the sole root-cause alarm while Internet is healthy" do
    set(Cluster.Signal.Enabled)
    set(Cluster.Signal.Unavailable)
    set(SSH.Signal.Enabled)
    set(SSH.Signal.Unavailable)
    set(SubnetRouter.Signal.Unavailable)
    set(Tailnet.Signal.Unavailable)

    wait_set(Tailnet.Alarm.Unavailable)
    refute_set(Internet.Alarm.Unavailable)
    refute_set(Cluster.Alarm.Unavailable)
    refute_set(SSH.Alarm.Unavailable)
    refute_set(SubnetRouter.Alarm.Unavailable)
  end

  test "an enabled broken cluster alarms only after every upstream layer" do
    set(Cluster.Signal.Enabled)
    set(Cluster.Signal.Unavailable)

    wait_set(Cluster.Alarm.Unavailable)
    refute_set(Internet.Alarm.Unavailable)
    refute_set(Tailnet.Alarm.Unavailable)
  end

  test "a persistent SSH listener error alarms only while Tailnet is healthy" do
    set(SSH.Signal.Enabled)
    set(SSH.Signal.Unavailable)

    wait_set(SSH.Alarm.Unavailable)
    refute_set(Internet.Alarm.Unavailable)
    refute_set(Tailnet.Alarm.Unavailable)
  end

  test "a route application failure alarms only while Tailnet is healthy" do
    set(SubnetRouter.Signal.Unavailable)

    wait_set(SubnetRouter.Alarm.Unavailable)
    refute_set(Internet.Alarm.Unavailable)
    refute_set(Tailnet.Alarm.Unavailable)
  end

  test "commissioning alarms are mutually exclusive" do
    set(Commissioning.Signal.AccessUnavailable)
    set(Commissioning.Signal.Required)

    wait_set(Commissioning.Alarm.Unavailable)
    refute_set(Commissioning.Alarm.Required)

    Alarms.clear(Commissioning.Signal.AccessUnavailable)
    wait_set(Commissioning.Alarm.Required)
    refute_set(Commissioning.Alarm.Unavailable)
  end

  test "storage failure is the sole root cause across commissioning and operations" do
    set(Storage.Signal.Failure)
    set(Commissioning.Signal.Required)
    set(Commissioning.Signal.AccessUnavailable)
    set(Internet.Signal.Unavailable)
    set(Tailnet.Signal.Unavailable)
    set(Cluster.Signal.Enabled)
    set(Cluster.Signal.Unavailable)
    set(SSH.Signal.Enabled)
    set(SSH.Signal.Unavailable)
    set(SubnetRouter.Signal.Unavailable)

    wait_set(Storage.Alarm.Failure)
    refute_set(Commissioning.Alarm.Required)
    refute_set(Commissioning.Alarm.Unavailable)
    refute_set(Internet.Alarm.Unavailable)
    refute_set(Tailnet.Alarm.Unavailable)
    refute_set(Cluster.Alarm.Unavailable)
    refute_set(SSH.Alarm.Unavailable)
    refute_set(SubnetRouter.Alarm.Unavailable)
  end

  test "candidate work preserves raw truth without feeding flapping history" do
    DeviceState.Alarms.changing(true)

    Internet.Alarms.report(%{online: false}, %{online: true})
    Tailnet.Alarms.report(%{online: false})
    Cluster.Alarms.report(true, true)
    SSH.Alarms.report(%{enabled: true, state: :error})
    SubnetRouter.Alarms.failure(true)
    Process.sleep(40)

    assert_set(Internet.Signal.Unavailable)
    assert_set(Tailnet.Signal.Unavailable)
    assert_set(Cluster.Signal.Unavailable)
    assert_set(SSH.Signal.Unavailable)
    assert_set(SubnetRouter.Signal.Unavailable)
    refute_set(Internet.Signal.UnavailableSample)
    refute Enum.any?(Alarms.public_ids(), &(Alarmist.alarm_state(&1) == :set))
  end

  test "Tailnet debounce restarts when Internet recovers" do
    set(Tailnet.Signal.Unavailable)
    Process.sleep(10)
    set(Internet.Signal.Unavailable)
    wait_for(fn -> Alarmist.alarm_state(Tailnet.Condition.ActionableUnavailable) != :set end)

    Alarms.clear(Internet.Signal.Unavailable)
    Process.sleep(10)
    refute_set(Tailnet.Alarm.Unavailable)
    wait_set(Tailnet.Alarm.Unavailable)
  end

  test "operational Internet transitions feed flapping history" do
    Internet.Alarms.report(%{online: false}, %{online: true})
    wait_set(Internet.Signal.UnavailableSample)

    Internet.Alarms.report(%{online: true}, %{online: false})
    wait_for(fn -> Alarmist.alarm_state(Internet.Signal.UnavailableSample) != :set end)
  end

  test "singular mode suppresses cluster failure" do
    set(Cluster.Signal.Unavailable)
    Process.sleep(40)
    refute_set(Cluster.Alarm.Unavailable)
  end

  defp initialize_clear(id) do
    :ok = Alarms.report_sync(id, true, id.description())
    :ok = Alarms.report_sync(id, false, id.description())
  end

  defp set(id), do: Alarms.set(id, id.description())
  defp assert_set(id), do: assert(Alarmist.alarm_state(id) == :set)
  defp refute_set(id), do: refute(Alarmist.alarm_state(id) == :set)
  defp wait_set(id), do: wait_for(fn -> Alarmist.alarm_state(id) == :set end)

  defp wait_for(predicate, attempts \\ 400) do
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
