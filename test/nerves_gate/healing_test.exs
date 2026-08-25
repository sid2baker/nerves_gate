defmodule NervesGate.HealingTest do
  use ExUnit.Case, async: false

  alias NervesGate.Alarms

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
end
