defmodule NervesGate.HealingTest do
  use ExUnit.Case, async: false

  alias NervesGate.Alarms
  alias NervesGate.Commissioning.Alarms, as: CommissioningAlarms
  alias NervesGate.DeviceState.Alarms, as: DeviceStateAlarms
  alias NervesGate.DeviceState.Server
  alias NervesGate.Internet
  alias NervesGate.Internet.Config
  alias NervesGate.Internet.Monitor
  alias NervesGate.TestScenario

  @healed_alarms [
    NervesGate.Commissioning.Alarm.Unavailable,
    NervesGate.Internet.Alarm.Unavailable,
    NervesGate.Tailnet.Alarm.Unavailable,
    NervesGate.Cluster.Alarm.Unavailable,
    NervesGate.SSH.Alarm.Unavailable,
    NervesGate.SubnetRouter.Alarm.Unavailable
  ]

  test "subsystems declare remedies independently of compiled alarm modules" do
    assert [
             {NervesGate.Commissioning.Alarm.Unavailable,
              {NervesGate.Commissioning.Alarms, :heal, 0},
              [retry_timeout: 60_000, callback_timeout: 15_000]},
             {NervesGate.Internet.Alarm.Unavailable, {NervesGate.Internet.Alarms, :heal, 0},
              [retry_timeout: 60_000, callback_timeout: 20_000]},
             {NervesGate.Tailnet.Alarm.Unavailable, {NervesGate.Tailnet.Alarms, :heal, 0},
              [retry_timeout: 60_000, callback_timeout: 10_000]},
             {NervesGate.Cluster.Alarm.Unavailable, {NervesGate.Cluster.Alarms, :heal, 0},
              [retry_timeout: 30_000, callback_timeout: 15_000]},
             {NervesGate.SSH.Alarm.Unavailable, {NervesGate.SSH.Alarms, :heal, 0},
              [retry_timeout: 30_000, callback_timeout: 15_000]},
             {NervesGate.SubnetRouter.Alarm.Unavailable,
              {NervesGate.SubnetRouter.Alarms, :heal, 0},
              [retry_timeout: 60_000, callback_timeout: 40_000]}
           ] = Alarms.remedy_declarations()

    assert Enum.all?(@healed_alarms, &is_nil(&1.__remedy__()))
  end

  test "test runtime leaves subsystem remedies unregistered" do
    refute Application.fetch_env!(:nerves_gate, :alarm_healing_enabled)

    assert Enum.all?(@healed_alarms, fn alarm ->
             is_nil(GenServer.whereis(Alarmist.RemedyWorker.via(alarm)))
           end)
  end

  test "runtime registers and removes declared remedies without recompilation" do
    try do
      assert :ok = Alarms.install(healing_enabled: true)

      assert Enum.all?(@healed_alarms, fn alarm ->
               is_pid(GenServer.whereis(Alarmist.RemedyWorker.via(alarm)))
             end)
    after
      assert :ok = Alarms.install(healing_enabled: false)
    end

    assert Enum.all?(@healed_alarms, fn alarm ->
             is_nil(GenServer.whereis(Alarmist.RemedyWorker.via(alarm)))
           end)
  end

  test "Internet healing observes but never reapplies configuration for link loss" do
    owner = self()
    original_server = :sys.get_state(Server)
    original_monitor = :sys.get_state(Monitor)

    current =
      original_server.current
      |> Map.put("configured", true)
      |> Map.put("internet", TestScenario.dhcp() |> Config.to_persisted())

    ops =
      Map.put(original_server.ops, :internet_restore, fn _config ->
        send(owner, :internet_restore)
        :ok
      end)

    DeviceStateAlarms.changing(true)
    :sys.replace_state(Server, &%{&1 | current: current, pending: nil, ops: ops})

    :sys.replace_state(Monitor, fn state ->
      %{state | last: %{online: false, ready: false, reason: :no_carrier, checks: %{}}}
    end)

    try do
      assert {:error, :physical_link_down} = Internet.Alarms.heal()
      refute_receive :internet_restore, 50
      assert_eventually(fn -> Monitor.status().reason != :no_carrier end)
    after
      :sys.replace_state(Server, fn _state -> original_server end)

      :sys.replace_state(Monitor, fn state ->
        %{state | last: original_monitor.last, interval: original_monitor.interval}
      end)

      if original_monitor.last, do: Internet.Alarms.report(original_monitor.last)
      CommissioningAlarms.required(not original_server.current["configured"])
      DeviceStateAlarms.changing(not is_nil(original_server.pending))
    end
  end

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
end
