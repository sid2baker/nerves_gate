defmodule NervesGate.IndicatorsTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Indicators, Network, Remote}
  alias NervesGate.Indicators.Host

  defmodule BlockedRecovery do
    def execute(_, owner) do
      send(owner, {:recovery_worker, self()})

      receive do
        :crash -> exit(:failed)
      end
    end
  end

  setup do
    host = start_supervised!({Host, name: nil})
    clock = start_supervised!({Agent, fn -> 1_000 end})
    remote_host = start_supervised!({Remote.Host, name: nil})
    remote = start_supervised!({Remote, name: nil, adapter: {Remote.Host, remote_host}})
    network_host = start_supervised!({Network.Host, name: nil})
    observed = Network.Host.snapshot(network_host)
    ports = Enum.map(observed.ports, &Map.put(&1, :connection, :internet))
    Network.Host.simulate(%{ports: ports}, network_host)
    network = start_supervised!({Network, name: nil, adapter: {Network.Host, network_host}})

    opts = [
      name: nil,
      adapter: {Host, host},
      recovery_adapter: {NervesGate.Recovery.Host, host},
      remote: remote,
      network: network,
      alarms: fn -> %{severity: :none, connection: false} end,
      clock: fn -> Agent.get(clock, & &1) end
    ]

    server = start_supervised!({Indicators, opts})
    assert Indicators.status(server).button.available

    %{
      server: server,
      host: host,
      clock: clock,
      remote_host: remote_host,
      opts: opts,
      api: [indicators: server, network: nil, remote: remote, equipment: nil, buses: nil]
    }
  end

  test "startup applies normal patterns, while status reads and subscriptions do not write",
       ctx do
    status = NervesGate.status(ctx.api)
    assert status.indicators.simulated
    assert status.indicators.led.patterns == %{run: "solid", user1: "off", user2: "off"}
    assert Host.snapshot(ctx.host).values == %{run: 1, user1: 0, user2: 0}
    writes = Host.snapshot(ctx.host).writes
    assert :ok = NervesGate.subscribe(ctx.api)
    assert Jason.encode!(NervesGate.status(ctx.api))
    refute Map.has_key?(status.actions, "button_mode")
    assert Host.snapshot(ctx.host).writes == writes
    refresh(ctx)
    assert Host.snapshot(ctx.host).writes == writes
  end

  test "identify is bounded, rejects overlap, then resumes newly observed status", ctx do
    assert :ok = NervesGate.identify(ctx.api)
    assert Indicators.status(ctx.server).led.identifying
    assert {:error, %{code: "operation_in_progress"}} = NervesGate.identify(ctx.api)
    Remote.Host.simulate(%{state: "online", auth_state: "authenticated"}, ctx.remote_host)
    advance(ctx, 500)
    assert Host.snapshot(ctx.host).values == %{run: 1, user1: 1, user2: 1}
    advance(ctx, 4_500)
    refute Indicators.status(ctx.server).led.identifying
    assert Host.snapshot(ctx.host).values == %{run: 1, user1: 1, user2: 0}
  end

  test "remote notifications update LEDs without waiting for reconciliation", ctx do
    Remote.Host.simulate(%{state: "online", auth_state: "authenticated"}, ctx.remote_host)
    eventually(fn -> Indicators.status(ctx.server).led.patterns.user1 == "solid" end)
    Remote.Host.simulate(%{available: false}, ctx.remote_host)
    eventually(fn -> Indicators.status(ctx.server).led.patterns.user1 == "slow" end)
    Remote.Host.simulate(%{auth_state: "stopped"}, ctx.remote_host)
    eventually(fn -> Indicators.status(ctx.server).led.patterns.user1 == "off" end)
  end

  test "first release arms; a short press identifies only on release", ctx do
    Host.button(1, ctx.host)
    advance(ctx, 40_000)
    Host.button(0, ctx.host)
    refute Indicators.status(ctx.server).led.identifying
    assert Host.snapshot(ctx.host).recoveries == []
    advance(ctx, 100)
    Host.button(1, ctx.host)
    refute Indicators.status(ctx.server).led.identifying
    advance(ctx, 200)
    Host.button(2, ctx.host)
    Host.button(1, ctx.host)
    Host.button(0, ctx.host)
    assert Indicators.status(ctx.server).led.identifying
    assert Indicators.status(ctx.server).button.last_pressed_at
  end

  test "feedback crosses thresholds, but recovery runs once and only on release", ctx do
    press(ctx)
    advance(ctx, 5_000)
    assert Indicators.status(ctx.server).led.patterns.run == "slow"
    assert Host.snapshot(ctx.host).recoveries == []
    advance(ctx, 20_000)
    assert Indicators.status(ctx.server).led.patterns.user2 == "fast"
    assert Host.snapshot(ctx.host).recoveries == []
    Host.button(0, ctx.host)
    eventually(fn -> Host.snapshot(ctx.host).recoveries == [:reboot] end)
    eventually(fn -> Indicators.status(ctx.server).recovery.status == "requested" end)
    Host.button(0, ctx.host)
    press(ctx)
    advance(ctx, 30_000)
    Host.button(0, ctx.host)
    assert Indicators.status(ctx.server).recovery.action == "reboot"
    assert Host.snapshot(ctx.host).recoveries == [:reboot]
  end

  test "30 seconds simulates reset then reboot; the workstation is untouched", ctx do
    press(ctx)
    advance(ctx, 30_000)

    assert Indicators.status(ctx.server).led.patterns == %{
             run: "fast",
             user1: "fast",
             user2: "fast"
           }

    assert Host.snapshot(ctx.host).recoveries == []
    Host.button(0, ctx.host)
    eventually(fn -> Host.snapshot(ctx.host).recoveries == [:factory_reset, :reboot] end)
    assert {:error, :recovery_unavailable} = NervesGate.Recovery.EC100.execute(:reboot, nil)

    assert {:error, :recovery_unavailable} =
             NervesGate.Recovery.EC100.execute(:factory_reset, nil)
  end

  test "failed reset is visible, never followed by reboot or another attempt", ctx do
    NervesGate.Indicators.Host.simulate(
      %{recovery_result: {:error, :data_unmount_failed}},
      ctx.host
    )

    press(ctx)
    advance(ctx, 30_000)
    Host.button(0, ctx.host)
    eventually(fn -> Indicators.status(ctx.server).recovery.status == "failed" end)
    assert Indicators.status(ctx.server).recovery.error.code == "data_unmount_failed"
    # Unnamed instances intentionally skip global alarms. Named recovery severity
    # and LED rendering are exercised with the real Alarmist in AlarmsTest.
    assert Host.snapshot(ctx.host).recoveries == [:factory_reset]
    press(ctx)
    advance(ctx, 30_000)
    Host.button(0, ctx.host)
    assert Host.snapshot(ctx.host).recoveries == [:factory_reset]
  end

  test "worker timeout does not block the event loop or retry", ctx do
    stop_supervised!(Indicators)

    opts =
      Keyword.merge(ctx.opts, recovery_adapter: {BlockedRecovery, self()}, recovery_ms: 60_000)

    server = start_supervised!({Indicators, opts})
    ctx = %{ctx | server: server}
    Indicators.status(server)
    press(ctx)
    advance(ctx, 5_000)
    Host.button(0, ctx.host)
    assert_receive {:recovery_worker, worker}, 1_000
    assert Indicators.status(server).recovery.status == "running"
    %{worker: {%Task{ref: ref}, timer}} = :sys.get_state(server)
    assert Process.read_timer(timer) <= 60_000
    send(server, {:recovery_timeout, ref})
    eventually(fn -> Indicators.status(server).recovery.status == "failed" end)
    refute Process.alive?(worker)
    assert Indicators.status(server).recovery.error.code == "recovery_outcome_unknown"
    refute_receive {:recovery_worker, _}
  end

  test "loss or dropped reports disarm the whole batch, including a queued release", ctx do
    press(ctx)
    advance(ctx, 30_000)

    send(
      ctx.server,
      {:input_event, "simulated:KEY_PROG1",
       [
         {:ev_key, :key_prog1, 0},
         {:ev_syn, :syn_dropped, 0}
       ]}
    )

    refute Indicators.status(ctx.server).button.armed
    assert Host.snapshot(ctx.host).recoveries == []
    press(ctx)
    advance(ctx, 30_000)
    send(ctx.server, {:input_event, "simulated:KEY_PROG1", :disconnect})
    refute Indicators.status(ctx.server).button.available
    refresh(ctx)
    Host.button(0, ctx.host)
    assert Host.snapshot(ctx.host).recoveries == []
    send(ctx.server, {:input_event, "/dev/input/event0", [{:ev_key, :key_prog1, 1}]})
    refute Indicators.status(ctx.server).led.identifying
  end

  test "failed writes leave other LEDs working and reconciliation retries current state", ctx do
    Host.simulate(%{write_error: [:user1]}, ctx.host)
    Remote.Host.simulate(%{state: "online", auth_state: "authenticated"}, ctx.remote_host)
    eventually(fn -> Indicators.status(ctx.server).led.restore_pending end)
    assert Host.snapshot(ctx.host).values.run == 1
    assert {:error, %{code: "led_unavailable"}} = NervesGate.identify(ctx.api)
    Host.simulate(%{write_error: []}, ctx.host)
    refresh(ctx)
    refute Indicators.status(ctx.server).led.restore_pending
    assert Indicators.status(ctx.server).led.error == nil
    assert Host.snapshot(ctx.host).values.user1 == 1
  end

  test "graceful shutdown turns controlled LEDs off; restart is disarmed", ctx do
    :ok = NervesGate.identify(ctx.api)
    stop_supervised!(Indicators)
    assert Host.snapshot(ctx.host).values == %{run: 0, user1: 0, user2: 0}
    server = start_supervised!({Indicators, ctx.opts})
    refute Indicators.status(server).button.armed
  end

  test "unsupported targets remain unavailable", ctx do
    server =
      start_supervised!({Indicators, name: nil, adapter: nil, remote: nil}, id: :unsupported)

    refute Indicators.status(server).available
    assert {:error, :led_unavailable} = Indicators.identify(server)
    refute NervesGate.status(Keyword.put(ctx.api, :indicators, nil)).indicators.available
  end

  defp press(ctx) do
    Host.button(0, ctx.host)
    advance(ctx, 100)
    Host.button(1, ctx.host)
    Indicators.status(ctx.server)
  end

  defp advance(ctx, ms) do
    Indicators.status(ctx.server)
    Agent.update(ctx.clock, &(&1 + ms))
    refresh(ctx)
  end

  defp refresh(ctx) do
    send(ctx.server, :refresh)
    Indicators.status(ctx.server)
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, remaining - 1)
        )
  end
end
