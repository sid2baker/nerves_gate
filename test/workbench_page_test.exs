defmodule WorkbenchWeb.WorkbenchPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import WorkbenchWeb.PageFixtures

  test "overview is a small landing page, not a collection of configuration forms" do
    document =
      render_component(&WorkbenchWeb.OverviewLive.render/1, assigns()) |> Floki.parse_document!()

    assert Floki.find(document, "#workbench-overview") != []
    assert Floki.find(document, "form") == []

    for path <- [
          "/devices",
          "/develop/applications",
          "/develop/firmware",
          "/provision"
        ] do
      assert Floki.find(document, "a[href='#{path}']") != []
    end
  end

  test "shared navigation highlights device details and keeps running work visible" do
    operation = %{operation() | kind: "firmware", status: :running, output: "Building image"}

    document =
      render_component(&WorkbenchWeb.Layouts.app/1,
        operation: operation,
        live_action: :devices,
        error: nil,
        inner_content: Phoenix.HTML.raw("<p>Device details</p>")
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "nav[aria-label='Workbench navigation'] a") |> length() == 4
    assert Floki.attribute(document, "nav a[aria-current=page]", "href") == ["/devices"]
    assert Floki.text(Floki.find(document, "#global-operation")) =~ "Firmware · running"
    assert Floki.attribute(document, "#global-operation", "href") == ["/develop/firmware"]
  end

  test "all firmware loop pages stay under Develop in the four-destination navigation" do
    for action <- [:apps, :firmware, :scenarios, :manual] do
      document =
        render_component(&WorkbenchWeb.Layouts.app/1,
          operation: operation(),
          live_action: action,
          error: nil,
          inner_content: Phoenix.HTML.raw("")
        )
        |> Floki.parse_document!()

      assert Floki.attribute(document, "nav a[aria-current=page]", "href") == ["/develop"]
      assert Floki.find(document, "nav a") |> length() == 4
    end
  end

  test "all pages share one LiveView session and network identities cannot route into simulator details" do
    for {path, view, action} <- [
          {"/", WorkbenchWeb.OverviewLive, :overview},
          {"/devices", WorkbenchWeb.DevicesLive, :devices},
          {"/devices/physical/ec100.local", WorkbenchWeb.PhysicalDeviceLive, :devices},
          {"/devices/gateway_a", WorkbenchWeb.DeviceLive, :devices},
          {"/develop/applications", WorkbenchWeb.ApplicationsLive, :apps},
          {"/develop/applications/demo", WorkbenchWeb.ApplicationsLive, :apps},
          {"/develop/firmware", WorkbenchWeb.FirmwareLive, :firmware},
          {"/provision", WorkbenchWeb.FactoryLive, :factory},
          {"/develop", WorkbenchWeb.ApplicationsLive, :apps},
          {"/develop/firmware/scenarios/gateway_a", WorkbenchWeb.DeviceLive, :scenarios},
          {"/develop/firmware/manual/gateway_a", WorkbenchWeb.DeviceLive, :manual},
          {"/test-lab/bench", WorkbenchWeb.FirmwareLive, :firmware},
          {"/test-lab/scenarios", WorkbenchWeb.FirmwareLive, :firmware},
          {"/test-lab/manual", WorkbenchWeb.FirmwareLive, :firmware},
          {"/test-lab/scenarios/gateway_a", WorkbenchWeb.DeviceLive, :scenarios},
          {"/test-lab/manual/gateway_a", WorkbenchWeb.DeviceLive, :manual}
        ] do
      route = Phoenix.Router.route_info(WorkbenchWeb.Router, "GET", path, "localhost")
      assert {^view, ^action, _, %{name: :workbench}} = route.phoenix_live_view
    end
  end
end
