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

  test "settings and workspace are separate, visits do not open ports, and observations update both browsers",
       ctx do
    {:ok, settings, html} = live(build_conn(), "/settings/buses")
    {:ok, workspace, _} = live(build_conn(), "/equipment/buses")
    assert html =~ "automatic-direction profile"
    assert html =~ "simulated buses"
    assert has_element?(settings, "a[aria-current=page]", "Settings")
    assert has_element?(workspace, "a[aria-current=page]", "Equipment")
    refute has_element?(workspace, "#configure-can0")
    assert has_element?(workspace, "#capture-can0[disabled]")
    assert Host.calls(ctx.host) == []

    settings
    |> form("#configure-can0", bus: %{port: "can0", enabled: "true", bitrate: "250000"})
    |> render_submit()

    eventually(fn -> has_element?(workspace, "#capture-can0:not([disabled])") end)
    workspace |> element("#capture-can0") |> render_click()
    assert has_element?(workspace, "#bus-operation", "capture on can0")
    eventually(fn -> has_element?(settings, "#bus-result", "01020304") end)
    assert has_element?(workspace, "#bus-result", "123")
  end

  test "serial enable is local opt-in; consent is required again for each Modbus read", ctx do
    {:ok, settings, _} = live(build_conn(), "/settings/buses")

    settings
    |> form("#configure-ttyS3", bus: %{port: "ttyS3", enabled: "true"})
    |> render_submit()

    assert Host.calls(ctx.host) == []
    {:ok, view, _} = live(build_conn(), "/equipment/buses")

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

    assert [_] = NervesGate.Buses.Host.calls(ctx.host)
  end

  test "loss of the domain disables actions and stale clicks do not crash the page" do
    {:ok, view, _} = live(build_conn(), "/equipment/buses")
    stop_supervised!(Buses)
    render_click(view, "capture", %{"port" => "ttyS0"})
    assert render(view) =~ "unsupported on this target or unavailable"
    refute has_element?(view, "#modbus-form")
    assert Process.alive?(view.pid)
    start_supervised!({Buses, adapter: nil})
    {:ok, settings, html} = live(build_conn(), "/settings/buses")
    assert html =~ "unsupported on this target or unavailable"
    refute has_element?(settings, "#configure-can0")
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
