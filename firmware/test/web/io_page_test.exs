defmodule NervesGateWeb.IOPageTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import NervesGate.IOFixture
  alias NervesGate.IO, as: GateIO
  @endpoint NervesGateWeb.Endpoint

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    start_supervised!({NervesGate.Settings, path: dir})
    NervesGate.IOFixture.start()
    start_supervised!(GateIO)
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

  test "confirmed forgetting removes an inactive input from the page and saved catalog" do
    assert {:ok, id} = plugin(Publisher, fn -> GateIO.register_input(input_definition()) end)
    Supervisor.terminate_child(FixtureSupervisor, Publisher)
    {:ok, view, _} = live(build_conn(), "/io")
    button = "#io-forget-io_fixture-temperature"
    assert has_element?(view, button <> "[data-confirm]", "Forget inactive endpoint")
    view |> element(button) |> render_click()
    assert render(view) =~ "Endpoint definition forgotten. No equipment commands were sent."
    refute has_element?(view, "#io-input-io_fixture-temperature")
    assert render(view) =~ "No plugin has registered an input."
    refute Map.has_key?(NervesGate.Settings.get(["io", "definitions"]), id)
    assert {:error, :unknown_input} = GateIO.input(id)
  end

  test "active inputs have no forget button and forged requests are refused" do
    register_pair()
    publish(21.5)
    {:ok, view, _} = live(build_conn(), "/io")
    refute has_element?(view, "#io-forget-io_fixture-temperature")
    render_click(view, "forget", %{"id" => "io_fixture.temperature"})
    assert render(view) =~ "Stop the endpoint&#39;s owning plugin"

    assert {:ok, %{available?: true, reading: %{value: 21.5}}} =
             GateIO.input("io_fixture.temperature")

    assert {:ok, %{claimed?: false, desired: nil}} = GateIO.output("io_fixture.setpoint")
  end

  test "a failed save retains the input and displays the recovery warning", %{tmp_dir: dir} do
    assert {:ok, id} = plugin(Publisher, fn -> GateIO.register_input(input_definition()) end)
    Supervisor.terminate_child(FixtureSupervisor, Publisher)
    {:ok, view, _} = live(build_conn(), "/io")
    blocker = NervesGate.Settings.file(dir) <> ".tmp"
    File.mkdir_p!(blocker)
    view |> element("#io-forget-io_fixture-temperature") |> render_click()
    assert render(view) =~ "The live endpoint was retained"
    assert has_element?(view, "#io-input-io_fixture-temperature")
    assert Map.has_key?(NervesGate.Settings.get(["io", "definitions"]), id)
    File.rmdir!(blocker)
  end

  test "inactive evidence cannot be forgotten and backend errors are shown" do
    register_pair()
    stop_supervised!(GateIO)
    start_supervised!(GateIO)
    {:ok, view, _} = live(build_conn(), "/io")
    view |> element("#io-forget-io_fixture-temperature") |> render_click()
    assert render(view) =~ "still used as output evidence"
    assert has_element?(view, "#io-input-io_fixture-temperature")
    assert has_element?(view, @output)
  end

  test "outputs use the same confirmed action, refuse active control, and disappear after inactive removal" do
    register_pair()
    :ok = GateIO.claim_output("io_fixture.setpoint")
    :ok = GateIO.set_output("io_fixture.setpoint", 22.0)
    {:ok, view, _} = live(build_conn(), "/io")
    refute has_element?(view, "#io-forget-io_fixture-setpoint")
    render_click(view, "forget", %{"id" => "io_fixture.setpoint"})
    assert render(view) =~ "Stop the endpoint&#39;s owning plugin"
    assert {:ok, %{owned?: true, desired: 22.0}} = GateIO.output("io_fixture.setpoint")
    Supervisor.terminate_child(FixtureSupervisor, Handler)
    send(view.pid, :poll)

    assert has_element?(
             view,
             "#io-forget-io_fixture-setpoint[data-confirm]",
             "Forget inactive endpoint"
           )

    view |> element("#io-forget-io_fixture-setpoint") |> render_click()
    assert render(view) =~ "Endpoint definition forgotten. No equipment commands were sent."
    refute has_element?(view, @output)
    assert has_element?(view, "#io-input-io_fixture-temperature")
    assert {:error, :unknown_output} = GateIO.output("io_fixture.setpoint")
    refute Map.has_key?(NervesGate.Settings.get(["io", "definitions"]), "io_fixture.setpoint")
    Supervisor.terminate_child(FixtureSupervisor, Publisher)
    send(view.pid, :poll)
    view |> element("#io-forget-io_fixture-temperature") |> render_click()
    refute has_element?(view, "#io-input-io_fixture-temperature")
    assert NervesGate.Settings.get(["io", "definitions"]) == %{}
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
