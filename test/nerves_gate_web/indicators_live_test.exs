defmodule NervesGateWeb.IndicatorsLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias NervesGate.Indicators
  alias NervesGate.Indicators.Host
  @endpoint NervesGateWeb.Endpoint

  setup do
    Supervisor.terminate_child(NervesGate.Supervisor, Indicators)
    host = start_supervised!({Host, name: nil})

    start_supervised!(
      {Indicators,
       adapter: {Host, host}, identify_ms: 240, recovery_adapter: {NervesGate.Recovery.Host, host}}
    )

    on_exit(fn ->
      NervesGate.Alarms.report(:recovery_failed, Indicators, false)
      Supervisor.restart_child(NervesGate.Supervisor, Indicators)
    end)

    Indicators.status()
    %{host: host}
  end

  test "settings explains fixed gestures and observes identify completion in two browsers", ctx do
    {:ok, view, html} = live(build_conn(), "/settings")
    {:ok, other, _} = live(build_conn(), "/settings")
    assert html =~ "simulated button, LEDs and recovery"
    assert html =~ "USER1"
    assert html =~ "USER2"
    assert html =~ "Actions happen only on release"
    assert html =~ "it deletes all saved data"
    assert html =~ "Physical reset qualification is still pending"
    refute has_element?(view, "#button-disabled")
    refute has_element?(view, "#button-identify")
    assert Host.snapshot(ctx.host).recoveries == []
    view |> element("#identify-gateway") |> render_click()
    assert has_element?(view, "#identify-gateway[disabled]")
    eventually(fn -> has_element?(other, "#led-state", "Identifying") end)
    eventually(fn -> has_element?(other, "#identify-gateway:not([disabled])") end)
    assert Host.snapshot(ctx.host).recoveries == []
  end

  test "obsolete/forged recovery events have no effects; absent indicators do not crash settings",
       ctx do
    {:ok, view, _} = live(build_conn(), "/settings")
    render_click(view, "button-mode", %{"mode" => "reset"})
    render_click(view, "factory-reset", %{})
    assert Host.snapshot(ctx.host).recoveries == []
    stop_supervised!(Indicators)
    render_click(view, "identify")
    assert has_element?(view, "#identify-gateway[disabled]")
    assert has_element?(view, "#led-state", "Unavailable")
    assert Process.alive?(view.pid)
  end

  test "recovery failures are visible in settings", ctx do
    NervesGate.Indicators.Host.simulate(
      %{recovery_result: {:error, :data_unmount_failed}},
      ctx.host
    )

    {:ok, view, _} = live(build_conn(), "/settings")

    :sys.replace_state(Indicators, fn state ->
      %{
        state
        | gesture: %{
            pressed_at: System.monotonic_time(:millisecond) - 30_100,
            released_at: System.monotonic_time(:millisecond) - 30_200
          }
      }
    end)

    Host.button(0, ctx.host)

    eventually(fn ->
      has_element?(view, "#recovery-error", "Could not unmount all data mounts")
    end)

    assert Host.snapshot(ctx.host).recoveries == [:factory_reset]
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, remaining - 1)
        )
  end
end
