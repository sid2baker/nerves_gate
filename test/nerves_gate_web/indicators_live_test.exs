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
    start_supervised!({Indicators, adapter: {Host, host}, blink_ms: 30, identify_ms: 240})
    on_exit(fn -> Supervisor.restart_child(NervesGate.Supervisor, Indicators) end)
    %{host: host}
  end

  test "settings offers safe controls, observes completion in two browsers, and never probes on visit",
       ctx do
    {:ok, view, html} = live(build_conn(), "/settings")
    {:ok, other, _} = live(build_conn(), "/settings")
    assert html =~ "simulated button and LED"
    assert html =~ "second LED is unsupported"
    assert html =~ "No reset, network or Tailscale action"
    assert has_element?(view, "#button-disabled[aria-pressed=true]")
    assert Host.snapshot(ctx.host).writes == []
    view |> element("#identify-gateway") |> render_click()
    assert has_element?(view, "#identify-gateway[disabled]")
    eventually(fn -> has_element?(other, "#led-state", "Identifying") end)
    eventually(fn -> has_element?(other, "#identify-gateway:not([disabled])") end)
    assert Host.snapshot(ctx.host).value == 0

    view |> element("#button-identify") |> render_click()
    eventually(fn -> has_element?(other, "#button-identify[aria-pressed=true]") end)
    Host.button(1, ctx.host)
    eventually(fn -> has_element?(view, "#button-last-press", "Last press:") end)
    eventually(fn -> has_element?(view, "#led-state", "Identifying") end)
    view |> element("#button-disabled") |> render_click()
    assert has_element?(view, "#button-disabled[aria-pressed=true]")
    eventually(fn -> has_element?(view, "#identify-gateway:not([disabled])") end)
    assert Host.snapshot(ctx.host).value == 0
  end

  test "forged modes are rejected and loss of indicators does not crash settings" do
    {:ok, view, _} = live(build_conn(), "/settings")

    assert render_click(view, "button-mode", %{"mode" => "reset"}) =~
             "No reset action is supported"

    assert Indicators.status().button.mode == "disabled"
    stop_supervised!(Indicators)
    render_click(view, "identify")
    assert has_element?(view, "#identify-gateway[disabled]")
    assert has_element?(view, "#led-state", "Unavailable")
    assert Process.alive?(view.pid)
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, remaining - 1)
    end
  end
end
