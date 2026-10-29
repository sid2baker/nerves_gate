defmodule NervesGateWeb.IOPageTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import NervesGate.IOFixture
  alias NervesGate.IO, as: GateIO
  @endpoint NervesGateWeb.Endpoint

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    NervesGate.IOFixture.start()
    start_supervised!({GateIO, path: Path.join(dir, "io.term")})
    start_supervised!(NervesGate.IO.Manual)
    start_supervised!(NervesGate.ProjectionServer)
    NervesGate.WebFixture.start_endpoint("io-page-test")
    :ok
  end

  @output "#io-output-io_fixture-setpoint"

  test "inputs and outputs show availability, freshness, writer and Status separately" do
    {:ok, view, html} = live(build_conn(), "/io")
    assert html =~ "No plugin has registered an input."
    assert has_element?(view, "nav a[aria-current=page][href='/io']", "I/O")

    register_pair()
    {:ok, _} = publish(21.5)
    send(view.pid, :poll)

    assert view |> element("#io-input-io_fixture-temperature") |> render() =~ "21.5 celsius"
    assert has_element?(view, "#io-input-io_fixture-temperature", "Fresh")
    output = view |> element(@output) |> render()
    assert output =~ "float · celsius · 0.0 – 40.0"
    assert output =~ "Target: none"
    assert output =~ "Free"
    assert output =~ "Unknown"
    assert output =~ "No Desire"
    assert output =~ "Readback · <code>io_fixture.temperature</code>"
    assert output =~ "Plugin holds the last value"
    refute has_element?(view, "#io-set-io_fixture-setpoint")

    # Another writer (an automation) owns it: no manual claim, set or release offered.
    :ok = plugin(Other, fn -> GateIO.claim_output("io_fixture.setpoint") end)
    send(view.pid, :poll)
    assert has_element?(view, @output, "Other writer")
    refute has_element?(view, "#io-claim-io_fixture-setpoint")
    refute has_element?(view, "#io-release-io_fixture-setpoint")
    :ok = plugin(Other, fn -> GateIO.release_output("io_fixture.setpoint") end)

    # Plugin loss: unavailable, never claimable.
    Supervisor.terminate_child(FixtureSupervisor, Handler)
    send(view.pid, :poll)
    assert has_element?(view, @output, "Plugin not running")
    assert has_element?(view, "#io-claim-io_fixture-setpoint[disabled]")
  end

  test "manual claim, validated set with a preserved draft, and release" do
    register_pair()
    {:ok, view, _} = live(build_conn(), "/io")

    view |> element("#io-claim-io_fixture-setpoint") |> render_click()
    assert render(view) =~ "Manual control taken. No value is set until you set one."
    assert has_element?(view, @output, "Manual control")
    assert {:ok, %{owned?: false, claimed?: true}} = GateIO.output("io_fixture.setpoint")

    form = element(view, "#io-set-io_fixture-setpoint")
    render_submit(form, %{"output" => "io_fixture.setpoint", "value" => "warm"})
    assert render(view) =~ "Enter a number."
    render_submit(form, %{"output" => "io_fixture.setpoint", "value" => "100"})
    assert render(view) =~ "does not match the output&#39;s type or limits"
    assert {:ok, %{desired: nil}} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)

    # A draft survives the periodic re-read until it is submitted.
    render_change(form, %{"output" => "io_fixture.setpoint", "value" => "23"})
    send(view.pid, :poll)
    assert has_element?(view, "#io-value-io_fixture-setpoint[value='23']")

    render_submit(form, %{"output" => "io_fixture.setpoint", "value" => "22.5"})
    assert render(view) =~ "Desired value stored. The plugin decides how the equipment follows"
    assert has_element?(view, @output, "Target: 22.5 celsius")
    assert {:ok, %{desired: 22.5}} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)
    assert has_element?(view, "#io-status-io_fixture-setpoint", "Pending")

    view |> element("#io-release-io_fixture-setpoint") |> render_click()
    assert render(view) =~ "the plugin&#39;s release behaviour applies"
    assert has_element?(view, @output, "Free")
    assert {:ok, %{desired: nil}} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)
  end

  test "form text converts only to the output's declared type" do
    alias NervesGateWeb.IOLive
    assert {:ok, true} = IOLive.parse(:boolean, "true")
    assert :error = IOLive.parse(:boolean, "yes")
    assert {:ok, 42} = IOLive.parse(:integer, " 42 ")
    assert :error = IOLive.parse(:integer, "42.0")
    assert {:ok, 22.0} = IOLive.parse(:float, "22")
    assert :error = IOLive.parse(:float, "22 °C")
    assert {:ok, "auto"} = IOLive.parse(:string, "auto")
    assert :error = IOLive.parse(:string, "")
  end
end
