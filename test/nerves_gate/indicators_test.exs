defmodule NervesGate.IndicatorsTest do
  use ExUnit.Case, async: true
  alias NervesGate.Indicators
  alias NervesGate.Indicators.Host

  setup do
    host = start_supervised!({Host, name: nil})

    server =
      start_supervised!(
        {Indicators, name: nil, adapter: {Host, host}, blink_ms: 10, identify_ms: 80}
      )

    assert Indicators.status(server).button.available

    %{
      server: server,
      host: host,
      api: [indicators: server, network: nil, remote: nil, equipment: nil]
    }
  end

  test "startup and reads never write the LED; host status is JSON encodable", ctx do
    status = NervesGate.status(ctx.api)
    assert status.indicators.simulated
    assert status.indicators.button.mode == "disabled"
    assert status.actions["identify"].enabled
    assert Host.snapshot(ctx.host).writes == []
    assert Jason.encode!(status) =~ "disabled"
    assert :ok = NervesGate.subscribe(ctx.api)
    assert Host.snapshot(ctx.host).writes == []
  end

  test "identify restores both prior raw values, rejects overlap, and publishes completion",
       ctx do
    :ok = NervesGate.subscribe(ctx.api)

    for previous <- [0, 1] do
      Host.simulate(%{value: previous}, ctx.host)
      assert :ok = NervesGate.identify(ctx.api)
      assert Host.snapshot(ctx.host).value == 1 - previous
      assert Indicators.status(ctx.server).led.identifying
      assert {:error, %{code: "operation_in_progress"}} = NervesGate.identify(ctx.api)
      refute NervesGate.status(ctx.api).actions["identify"].enabled
      eventually(fn -> not Indicators.status(ctx.server).led.identifying end)
      assert Host.snapshot(ctx.host).value == previous
      refute Indicators.status(ctx.server).led.restore_pending
      assert_receive %PropertyTable.Event{}
    end
  end

  test "disabled button observes presses without effects, with no reset mode", ctx do
    Host.button(1, ctx.host)
    assert Indicators.status(ctx.server).button.last_pressed_at
    assert Host.snapshot(ctx.host).writes == []

    for mode <- ["reset", "factory_reset", "health", nil, %{}, :identify] do
      assert {:error, %{code: "invalid_parameters"}} = NervesGate.button_mode(mode, ctx.api)
    end

    assert Indicators.status(ctx.server).button.mode == "disabled"
  end

  test "only the discovered key press identifies; held keys and bounce cannot extend it", ctx do
    :ok = NervesGate.button_mode("identify", ctx.api)
    send(ctx.server, {:input_event, "/dev/input/event0", [{:ev_key, :key_prog1, 1}]})
    send(ctx.server, {:input_event, "simulated:KEY_PROG1", [{:ev_key, :key_power, 1}]})
    Host.button(2, ctx.host)
    refute Indicators.status(ctx.server).led.identifying
    Host.button(1, ctx.host)
    assert Indicators.status(ctx.server).led.identifying
    pressed_at = Indicators.status(ctx.server).button.last_pressed_at

    for _ <- 1..10 do
      Host.button(2, ctx.host)
      Host.button(1, ctx.host)
    end

    eventually(fn -> not Indicators.status(ctx.server).led.identifying end)
    assert Host.snapshot(ctx.host).value == 0
    Host.button(1, ctx.host)
    refute Indicators.status(ctx.server).led.identifying
    Host.button(0, ctx.host)
    Host.button(1, ctx.host)
    assert Indicators.status(ctx.server).button.last_pressed_at == pressed_at
    refute Indicators.status(ctx.server).led.identifying
  end

  test "disabling the button does not cancel restoration of an in-flight identify", ctx do
    :ok = NervesGate.button_mode("identify", ctx.api)
    Host.button(1, ctx.host)
    assert Indicators.status(ctx.server).led.identifying
    :ok = NervesGate.button_mode("disabled", ctx.api)
    eventually(fn -> not Indicators.status(ctx.server).led.identifying end)
    assert Host.snapshot(ctx.host).value == 0
  end

  test "unavailable LED does not start; failed restoration blocks new work and retries", ctx do
    Host.simulate(%{read_error: true}, ctx.host)
    assert {:error, %{code: "led_unavailable"}} = NervesGate.identify(ctx.api)
    assert Host.snapshot(ctx.host).writes == []
    Host.simulate(%{read_error: false}, ctx.host)
    assert :ok = NervesGate.identify(ctx.api)
    Host.simulate(%{write_error: true}, ctx.host)
    eventually(fn -> Indicators.status(ctx.server).led.restore_pending end)
    assert Indicators.status(ctx.server).led.error.code == "led_restore_failed"
    assert {:error, %{code: "operation_in_progress"}} = NervesGate.identify(ctx.api)
    Host.simulate(%{write_error: false}, ctx.host)
    send(ctx.server, :poll)
    refute Indicators.status(ctx.server).led.restore_pending
    assert Indicators.status(ctx.server).led.error == nil
    assert Host.snapshot(ctx.host).value == 0
  end

  test "graceful shutdown restores the LED and restart defaults the button to disabled", ctx do
    :ok = NervesGate.button_mode("identify", ctx.api)
    :ok = NervesGate.identify(ctx.api)
    stop_supervised!(Indicators)
    assert Host.snapshot(ctx.host).value == 0
    server = start_supervised!({Indicators, name: nil, adapter: {Host, ctx.host}})
    assert Indicators.status(server).button.mode == "disabled"
  end

  test "lost button is unavailable until rediscovery; unrecognized messages are harmless", ctx do
    send(ctx.server, {:input_event, "simulated:KEY_PROG1", :disconnect})
    refute Indicators.status(ctx.server).button.available
    assert {:error, %{code: "button_unavailable"}} = NervesGate.button_mode("identify", ctx.api)
    send(ctx.server, {:input_event, "simulated:KEY_PROG1", [{:ev_key, :key_prog1, 1}]})
    send(ctx.server, {:blink, make_ref()})
    assert Host.snapshot(ctx.host).writes == []
    send(ctx.server, :poll)
    assert Indicators.status(ctx.server).button.available
  end

  test "unsupported targets and absent domain servers fail closed", ctx do
    server = start_supervised!({Indicators, name: nil, adapter: nil}, id: :unsupported)
    refute Indicators.status(server).available
    assert {:error, :led_unavailable} = Indicators.identify(server)
    assert {:error, :button_unavailable} = Indicators.button_mode("identify", server)
    assert :ok = Indicators.button_mode("disabled", server)
    api = Keyword.put(ctx.api, :indicators, nil)
    refute NervesGate.status(api).indicators.available
    refute NervesGate.status(api).actions["identify"].enabled
    assert {:error, _} = NervesGate.identify(api)
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      eventually(fun, remaining - 1)
    end
  end
end
