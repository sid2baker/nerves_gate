defmodule WorkbenchWeb.DevicesPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import WorkbenchWeb.PageFixtures

  test "unified directory shows simulated and unverified physical devices with safe separate links" do
    {:ok, gateway} = Workbench.LANDiscovery.manual("ec100.example.ts.net")
    bench = bench()
    discovery = %{status: :idle, devices: [gateway], error: nil}
    devices = Workbench.Devices.list(bench, discovery)
    values = assigns(devices: devices, discovery: discovery, kind: "all", query: "")

    document =
      render_component(&WorkbenchWeb.DevicesLive.render/1, values) |> Floki.parse_document!()

    assert Floki.find(
             document,
             "#device-directory tr[data-device-kind=simulated] a[href='/devices/gateway_a']"
           ) != []

    assert Floki.find(
             document,
             "#device-directory tr[data-device-kind=physical] a[href='/devices/physical/ec100.example.ts.net']"
           ) != []

    assert Floki.text(document) =~ "Simulated · QEMU"
    assert Floki.text(document) =~ "Unverified"
    assert Floki.find(document, "#add-address input[name=address]") != []
    assert Floki.find(document, "[phx-click=lifecycle]") == []

    filtered =
      render_component(
        &WorkbenchWeb.DevicesLive.render/1,
        Keyword.put(values, :kind, "simulated")
      )
      |> Floki.parse_document!()

    assert Floki.find(filtered, "#device-directory tr[data-device-kind=physical]") == []
  end

  test "only configured simulator details receive the simulated badge and test controls are a separate tab" do
    for id <- ["gateway_a", "unknown"] do
      values =
        assigns(
          id: id,
          tab: :devices,
          confirm_run: nil,
          projection: NervesGate.Projection.disconnected().status
        )

      values =
        Keyword.merge(values, Map.to_list(WorkbenchWeb.DeviceLive.bench_assigns(bench(), id)))

      document =
        render_component(&WorkbenchWeb.DeviceLive.render/1, values) |> Floki.parse_document!()

      assert Floki.find(document, "[data-device-kind=simulated]") != [] == (id == "gateway_a")
      assert Floki.find(document, "#test-results") == []
      assert Floki.find(document, "#review-firmware") == []
      refute Floki.text(document) =~ "mix dev.ui"
    end
  end

  test "skipped scenarios show their missing requirements instead of a pass" do
    scenario = Scenarios.describe(Scenarios.Cases.CableLoss)
    reason = "Missing requirements: fixture:ethernet_link"
    row = %{id: scenario.id, status: :skipped, detail: reason, milliseconds: 0}

    device = %{
      owner: nil,
      manual_action: nil,
      blocked: false,
      faults: %{},
      topology: %{lan1: :internet, lan2: :application},
      ui: "http://localhost:4001",
      run: 1
    }

    view =
      Map.merge(bench(), %{
        scenarios: [scenario],
        devices: %{gateway_a: device},
        runs: [%{id: 1, rows: [row]}]
      })

    values =
      assigns(
        id: "gateway_a",
        tab: :scenarios,
        confirm_run: nil,
        projection: NervesGate.Projection.disconnected().status
      )
      |> Keyword.merge(Map.to_list(WorkbenchWeb.DeviceLive.bench_assigns(view, "gateway_a")))

    document =
      render_component(&WorkbenchWeb.DeviceLive.render/1, values) |> Floki.parse_document!()

    assert Floki.attribute(document, "#device-ui-link", "href") == ["http://localhost:4001"]
    result = Floki.find(document, "#scenario-cable_loss") |> Floki.text()
    assert result =~ "skipped"
    assert result =~ reason
    refute result =~ "passed"
  end

  test "firmware device workspaces keep manual admission separate from scenario controls" do
    device = %{
      owner: :manual,
      manual_action: nil,
      blocked: false,
      faults: %{"vm" => "VM paused"},
      topology: %{lan1: :internet, lan2: :application},
      ui: "http://localhost:4001",
      run: nil
    }

    view = Map.merge(bench(), %{devices: %{gateway_a: device}, scenarios: []})

    values =
      assigns(
        id: "gateway_a",
        confirm_run: nil,
        projection: NervesGate.Projection.disconnected().status
      )
      |> Keyword.merge(Map.to_list(WorkbenchWeb.DeviceLive.bench_assigns(view, "gateway_a")))

    for tab <- [:devices, :scenarios, :manual] do
      document =
        render_component(&WorkbenchWeb.DeviceLive.render/1, Keyword.put(values, :tab, tab))
        |> Floki.parse_document!()

      assert Floki.find(document, "#manual-controls") != [] == (tab == :manual)
      assert Floki.find(document, "#manual-console") != [] == (tab == :manual)
      assert Floki.find(document, "#scenarios") == []
      assert Floki.find(document, "#mode-scenarios") != [] == (tab != :devices)
      assert Floki.find(document, "#device-summary") != []
      assert Floki.find(document, "a[href='/develop/firmware/manual/gateway_a']") != []
    end
  end
end
