defmodule WorkbenchWeb.WorkbenchPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import WorkbenchWeb.PageFixtures

  test "home links the four destinations and lists gateways with connection state" do
    offline = gateway(%{node: :"nerves_gate@10.0.0.5", connected: false})

    document =
      render_component(
        &WorkbenchWeb.OverviewLive.render/1,
        assigns(gateways: [gateway(), offline])
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "form") == []

    for path <- ["/devices", "/develop/applications", "/develop/firmware", "/provision"],
        do: assert(Floki.find(document, "a[href='#{path}']") != [])

    text = Floki.text(Floki.find(document, "#home-gateways"))
    assert text =~ "Connected"
    assert text =~ "Last seen 2026-10-27 12:00:00 UTC"
  end

  test "shared navigation highlights sections and keeps the running job visible" do
    job = %{job() | kind: "firmware", status: :running}

    for {action, href} <- [
          devices: "/devices",
          scenarios: "/devices",
          manual: "/devices",
          apps: "/develop/applications",
          firmware: "/develop/applications"
        ] do
      document =
        render_component(&WorkbenchWeb.Layouts.app/1,
          job: job,
          live_action: action,
          error: nil,
          inner_content: Phoenix.HTML.raw("")
        )
        |> Floki.parse_document!()

      assert Floki.attribute(document, "nav a[aria-current=page]", "href") == [href]
      assert Floki.find(document, "nav[aria-label='Workbench navigation'] a") |> length() == 4
      assert Floki.text(Floki.find(document, "#global-job")) =~ "Firmware build · running"
    end
  end

  test "routes: one LiveView session, gateways addressed by node" do
    for {path, view, action} <- [
          {"/", WorkbenchWeb.OverviewLive, :overview},
          {"/devices", WorkbenchWeb.DevicesLive, :devices},
          {"/devices/nerves_gate@10.203.42.2", WorkbenchWeb.GatewayLive, :devices},
          {"/devices/nerves_gate@10.203.42.2/scenarios", WorkbenchWeb.GatewayLive, :scenarios},
          {"/devices/nerves_gate@10.203.42.2/manual", WorkbenchWeb.GatewayLive, :manual},
          {"/develop/applications", WorkbenchWeb.ApplicationsLive, :apps},
          {"/develop/applications/demo", WorkbenchWeb.ApplicationsLive, :apps},
          {"/develop/firmware", WorkbenchWeb.FirmwareLive, :firmware},
          {"/provision", WorkbenchWeb.FactoryLive, :factory}
        ] do
      route = Phoenix.Router.route_info(WorkbenchWeb.Router, "GET", path, "localhost")
      assert {^view, ^action, _, %{name: :workbench}} = route.phoenix_live_view
    end

    for path <- [
          "/develop",
          "/simulator",
          "/api/state",
          "/test-lab/bench",
          "/devices/physical/ec100.local/x"
        ],
        do:
          assert(
            :error == Phoenix.Router.route_info(WorkbenchWeb.Router, "GET", path, "localhost")
          )
  end

  test "devices page lists simulated and physical gateways the same way" do
    simulated =
      gateway(%{
        node: :"nerves_gate@10.203.42.2",
        address: "10.203.42.2",
        source: :qemu,
        sim_id: :gateway_a
      })

    never =
      gateway(%{node: :"nerves_gate@10.0.0.7", connected: false, last_seen: nil, identity: nil})

    document =
      render_component(
        &WorkbenchWeb.DevicesLive.render/1,
        assigns(gateways: [gateway(), simulated, never])
      )
      |> Floki.parse_document!()

    assert Floki.attribute(document, "#gateways a", "href") == [
             "/devices/nerves_gate@100.64.0.9",
             "/devices/nerves_gate@10.203.42.2",
             "/devices/nerves_gate@10.0.0.7"
           ]

    assert Floki.attribute(document, "[data-device-kind]", "data-device-kind") == [
             "network",
             "qemu",
             "network"
           ]

    assert Floki.text(document) =~ "Never connected"
    assert Floki.find(document, "#add-gateway input[name=address]") != []
  end
end
