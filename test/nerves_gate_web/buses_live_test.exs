defmodule NervesGateWeb.BusesLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias NervesGate.Buses
  alias NervesGate.Buses.Host
  @endpoint NervesGateWeb.Endpoint

  setup do
    Supervisor.terminate_child(NervesGate.Supervisor, Buses)
    host = start_supervised!({Host, name: nil})
    Host.simulate(%{delay: 150}, host)
    start_supervised!({Buses, adapter: {Host, host}})
    on_exit(fn -> Supervisor.restart_child(NervesGate.Supervisor, Buses) end)
    %{host: host}
  end

  test "each bus page combines configuration and diagnostics; visits never open ports", ctx do
    for {path, name, title} <- [
          {"/equipment/can/1", "can0", "CAN 1"},
          {"/equipment/can/2", "can1", "CAN 2"},
          {"/equipment/rs485/1", "ttyS3", "RS485 1"},
          {"/equipment/rs485/2", "ttyS4", "RS485 2"}
        ] do
      {:ok, view, html} = live(build_conn(), path)
      assert has_element?(view, "h1", title)
      assert html =~ "simulated buses"
      assert has_element?(view, "a[aria-current=page]", "Equipment")
      assert has_element?(view, "#configure-#{name}")
      assert has_element?(view, "#capture-#{name}[disabled]")

      for other <- ["can0", "can1", "ttyS3", "ttyS4"] -- [name],
          do: refute(has_element?(view, "#port-#{other}"))

      assert has_element?(view, "#modbus-form") == String.starts_with?(name, "tty")
    end

    assert Host.calls(ctx.host) == []
  end

  test "two browsers observe operations on the same port, not results on other ports", ctx do
    {:ok, view, _} = live(build_conn(), "/equipment/can/1")
    {:ok, other, _} = live(build_conn(), "/equipment/can/1")
    {:ok, different, _} = live(build_conn(), "/equipment/can/2")

    view
    |> form("#configure-can0", bus: %{port: "can0", enabled: "true", bitrate: "250000"})
    |> render_submit()

    eventually(fn -> has_element?(other, "#capture-can0:not([disabled])") end)
    other |> element("#capture-can0") |> render_click()
    assert has_element?(other, "#bus-operation", "capture on can0")
    eventually(fn -> has_element?(view, "#bus-result", "01020304") end)
    assert has_element?(other, "#bus-result", "123")
    refute has_element?(different, "#bus-result")
    assert [{:capture, "can0", _}, {:configure, "can0", _}] = Host.calls(ctx.host)
  end

  test "serial enable is local opt-in; consent is required again for each Modbus read", ctx do
    {:ok, view, _} = live(build_conn(), "/equipment/rs485/1")
    assert render(view) =~ "automatic-direction profile"
    view |> form("#configure-ttyS3", bus: %{port: "ttyS3", enabled: "true"}) |> render_submit()
    assert Host.calls(ctx.host) == []

    params = %{
      "port" => "ttyS3",
      "unit" => "1",
      "function" => "4",
      "address" => "10",
      "count" => "2",
      "authorized" => "false"
    }

    assert render_submit(view, "modbus-read", %{"modbus" => params}) =~ "Authorize one read"
    assert Host.calls(ctx.host) == []
    view |> form("#modbus-form", modbus: %{params | "authorized" => "true"}) |> render_submit()
    refute has_element?(view, "input[type=checkbox][checked]")
    eventually(fn -> has_element?(view, "#bus-result", "Address 10:") end)
    assert render(view) =~ "No broadcasts, writes, unit scans or retries"
    assert [{:modbus_read, "ttyS3", %{function: 4, count: 2}}] = Host.calls(ctx.host)

    assert render_submit(view, "modbus-read", %{"modbus" => %{params | "function" => "6"}}) =~
             "Authorize one read"

    assert [_] = Host.calls(ctx.host)
  end

  test "forged events cannot target a different port or expose another bus's controls", ctx do
    {:ok, view, _} = live(build_conn(), "/equipment/rs485/1")
    params = %{"port" => "ttyS4", "enabled" => "true", "authorized" => "true"}

    for event <- ["change-config", "configure"],
        do: render_submit(view, event, %{"bus" => params})

    for event <- ["change-modbus", "modbus-read"],
        do: render_submit(view, event, %{"modbus" => params})

    render_click(view, "capture", %{"port" => "ttyS4"})
    render_click(view, "capture", %{"port" => "ttyS0"})
    assert Host.calls(ctx.host) == []
    assert render(view) =~ "does not match the selected port"
    assert has_element?(view, "input[name='modbus[port]'][value=ttyS3]")
    refute has_element?(view, "#configure-ttyS4")
    refute Enum.find(Buses.status().ports, &(&1.name == "ttyS4")).enabled
  end

  test "invalid bus IDs return to Equipment without I/O", ctx do
    for path <- [
          "/equipment/can/3",
          "/equipment/can/can0",
          "/equipment/rs485/0",
          "/equipment/rs485/ttyS0"
        ] do
      assert {:error, {:live_redirect, %{to: "/equipment"}}} = live(build_conn(), path)
    end

    assert Host.calls(ctx.host) == []
  end

  test "loss of the domain disables actions and stale clicks do not crash the page" do
    {:ok, view, _} = live(build_conn(), "/equipment/rs485/1")
    stop_supervised!(Buses)
    render_click(view, "capture", %{"port" => "ttyS3"})
    assert render(view) =~ "unsupported on this target or unavailable"
    refute has_element?(view, "#modbus-form")
    assert Process.alive?(view.pid)
    start_supervised!({Buses, adapter: nil})
    {:ok, missing, html} = live(build_conn(), "/equipment/can/1")
    assert html =~ "unsupported on this target or unavailable"
    refute has_element?(missing, "#configure-can0")
    {:ok, index, _} = live(build_conn(), "/equipment")

    for kind <- ["rs485", "can"],
        number <- 1..2,
        do: assert(has_element?(index, "#equipment-#{kind}-#{number}", "Unavailable"))
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
