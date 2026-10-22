defmodule DevWeb.WorkbenchPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]

  test "overview is a small landing page, not a collection of configuration forms" do
    document =
      render_component(&DevWeb.OverviewLive.render/1, assigns()) |> Floki.parse_document!()

    assert Floki.find(document, "#workbench-overview") != []
    assert Floki.find(document, "form") == []

    for path <- ["/devices", "/apps", "/firmware", "/simulator"] do
      assert Floki.find(document, "a[href='#{path}']") != []
    end
  end

  test "shared navigation highlights device details and keeps running work visible" do
    operation = %{operation() | kind: "firmware", status: :running, output: "Building image"}

    document =
      render_component(&DevWeb.Layouts.app/1,
        operation: operation,
        live_action: :devices,
        error: nil,
        inner_content: Phoenix.HTML.raw("<p>Device details</p>")
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "nav[aria-label='Workbench navigation'] a") |> length() == 6
    assert Floki.attribute(document, "nav a[aria-current=page]", "href") == ["/devices"]
    assert Floki.text(Floki.find(document, "#global-operation")) =~ "Firmware · running"
    assert Floki.attribute(document, "#global-operation", "href") == ["/firmware"]
  end

  test "application list creates/opens ordinary projects, details own test/package/install" do
    app = %{path: "/projects/demo", name: "demo"}

    document =
      render_component(
        &DevWeb.ApplicationsLive.render/1,
        assigns(applications: [app], app_id: nil, app: nil)
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "#create-application input[name='application[path]']") != []
    assert Floki.find(document, "#open-application input[name='application[path]']") != []
    assert Floki.find(document, "button[phx-value-kind=test]") == []
    [path] = Floki.attribute(document, "#applications a", "href")
    assert path == "/apps/" <> Base.url_encode64(app.path, padding: false)

    document =
      render_component(
        &DevWeb.ApplicationsLive.render/1,
        assigns(applications: [app], app_id: "demo", app: app)
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "#application-actions button[phx-value-kind=test]") != []
    assert Floki.find(document, "#application-actions button[phx-value-kind=package]") != []
    assert Floki.find(document, "#install-application select[name=device]") != []
    assert Floki.find(document, "#create-application") == []
  end

  test "unified directory shows simulated and unverified physical devices with safe separate links" do
    {:ok, gateway} = Dev.Discovery.manual("ec100.example.ts.net")
    bench = bench()
    discovery = %{status: :idle, devices: [gateway], error: nil}
    devices = Dev.Devices.list(bench, discovery)
    values = assigns(devices: devices, discovery: discovery, kind: "all", query: "")
    document = render_component(&DevWeb.DevicesLive.render/1, values) |> Floki.parse_document!()

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
      render_component(&DevWeb.DevicesLive.render/1, Keyword.put(values, :kind, "simulated"))
      |> Floki.parse_document!()

    assert Floki.find(filtered, "#device-directory tr[data-device-kind=physical]") == []
  end

  test "physical review stays on its selected device and typed confirmation never leaks to another device" do
    {:ok, device} = Dev.Discovery.manual("ec100.example.ts.net")

    review = %{
      address: device.address,
      port: 22,
      target: "ec100",
      current_version: "0.1.0",
      version: "0.2.0-dev",
      serial: "controller",
      firmware: "/images/ec100.fw",
      sha256: String.duplicate("a", 64),
      token: "review-id"
    }

    values = assigns(device: device, tab: "firmware", operation: %{operation() | review: review})

    document =
      render_component(&DevWeb.PhysicalDeviceLive.render/1, values) |> Floki.parse_document!()

    assert Floki.find(document, "#review-firmware input[name=address]") == []
    assert Floki.find(document, "#review-firmware input[name=port]") == []
    assert Floki.find(document, "#review-firmware input[name=firmware]") == []
    assert Floki.find(document, "#review-firmware select[name=firmware]") != []
    assert Floki.find(document, "#firmware-confirmation input[name=address][required]") != []

    assert Floki.find(document, "#firmware-confirmation input[name=review_id][value=review-id]") !=
             []

    assert Floki.text(document) =~ "Update firmware and reboot"
    assert Floki.text(document) =~ "SHA-256"
    assert Floki.find(document, "[phx-click=lifecycle], [phx-click=manual], #scenarios") == []

    other = %{device | address: "other.local"}

    document =
      render_component(&DevWeb.PhysicalDeviceLive.render/1, Keyword.put(values, :device, other))
      |> Floki.parse_document!()

    assert Floki.find(document, "#firmware-confirmation") == []
  end

  test "physical overview is read-only and a review links back to its firmware tab" do
    {:ok, device} = Dev.Discovery.manual("ec100.example.ts.net")
    values = assigns(device: device, tab: "overview")

    document =
      render_component(&DevWeb.PhysicalDeviceLive.render/1, values) |> Floki.parse_document!()

    assert Floki.find(document, "form") == []
    assert Floki.find(document, "button[phx-click=read_info]") != []
    assert Floki.text(document) =~ "Not read yet"
    assert Floki.text(document) =~ "Manually added"

    assert Floki.find(document, "nav[aria-label='Device sections'] a[href$='?tab=firmware']") !=
             []

    assert DevWeb.Components.operation_path(%{review: %{address: device.address}}) ==
             "/devices/physical/ec100.example.ts.net?tab=firmware"
  end

  test "firmware picker lists image versions and disables review until an image exists" do
    {:ok, device} = Dev.Discovery.manual("ec100.example.ts.net")
    values = assigns(device: device, tab: "firmware")

    empty =
      render_component(&DevWeb.PhysicalDeviceLive.render/1, values) |> Floki.parse_document!()

    assert Floki.find(empty, "#review-firmware select[disabled]") != []
    assert Floki.find(empty, "#review-firmware button[type=submit][disabled]") != []

    images = [%{path: "/built/ec100.fw", version: "0.2.0-dev", build: "ec100_dev/nerves_gate.fw"}]

    document =
      render_component(&DevWeb.PhysicalDeviceLive.render/1, Keyword.put(values, :images, images))
      |> Floki.parse_document!()

    assert Floki.find(document, "select[name=firmware] option[value='/built/ec100.fw']") != []
    assert Floki.text(document) =~ "0.2.0-dev"
    assert Floki.find(document, "#review-firmware button[disabled]") == []
  end

  test "read information only shows whitelisted SSH observations and their timestamp" do
    {:ok, device} = Dev.Discovery.manual("ec100.example.ts.net")

    device =
      Map.merge(device, %{
        target: "ec100",
        version: "0.2.0-dev",
        identity: %{
          values: %{"serial" => "serial-42", "architecture" => "arm"},
          read_at: "2026-10-22T12:00:00Z"
        }
      })

    document =
      render_component(
        &DevWeb.PhysicalDeviceLive.render/1,
        assigns(device: device, tab: "overview")
      )
      |> Floki.parse_document!()

    assert Floki.text(document) =~ "serial-42"
    assert Floki.text(document) =~ "2026-10-22T12:00:00Z"
    assert Floki.text(document) =~ "not a live connection"
    assert Floki.text(document) =~ "0.2.0-dev"
  end

  test "only configured simulator details receive the simulated badge and test controls are a separate tab" do
    for id <- ["gateway_a", "unknown"] do
      values =
        assigns(
          id: id,
          tab: "overview",
          confirm_run: nil,
          projection: NervesGate.Projection.disconnected().status
        )

      values = Keyword.merge(values, Map.to_list(DevWeb.DeviceLive.bench_assigns(bench(), id)))
      document = render_component(&DevWeb.DeviceLive.render/1, values) |> Floki.parse_document!()
      assert Floki.find(document, "[data-device-kind=simulated]") != [] == (id == "gateway_a")
      assert Floki.find(document, "#test-results") == []
      assert Floki.find(document, "#review-firmware") == []
    end
  end

  test "factory provisioning is separate, explicit and never offers backup bypass" do
    empty = render_component(&DevWeb.FactoryLive.render/1, assigns()) |> Floki.parse_document!()
    assert Floki.find(empty, "#review-factory select[name=firmware][disabled]") != []
    assert Floki.find(empty, "#confirm-factory") == []
    assert Floki.find(empty, "input[type=password], input[name=backup]") == []
    assert Floki.text(empty) =~ "RAM"
    assert Floki.text(empty) =~ "not a verified EC100 serial number"

    review = %{
      kind: :factory,
      token: "factory-token",
      location: "101",
      confirmation: "ERASE EC100 101",
      version: "0.2.0-dev",
      firmware: "/images/ec100.fw",
      backup: "/backups/review",
      capacity: 4_000_000_000,
      required_space: 12_000_000_000,
      available_space: 20_000_000_000,
      sha256: String.duplicate("a", 64)
    }

    operation = %{
      operation()
      | status: :awaiting_confirmation,
        kind: "factory_review",
        review: review
    }

    document =
      render_component(&DevWeb.FactoryLive.render/1, assigns(operation: operation))
      |> Floki.parse_document!()

    assert Floki.find(
             document,
             "#confirm-factory input[name=identified][type=checkbox][required]"
           ) != []

    assert Floki.find(document, "#confirm-factory input[name=confirmation][required]") != []
    assert Floki.attribute(document, "input[name=review_id]", "value") == ["factory-token"]
    assert Floki.text(document) =~ "ERASE EC100 101"
    assert Floki.text(document) =~ "full eMMC user-area backup"
    assert DevWeb.Components.operation_path(operation) == "/factory"

    {:ok, device} = Dev.Discovery.manual("ec100.local")

    other =
      render_component(
        &DevWeb.PhysicalDeviceLive.render/1,
        assigns(device: device, tab: "firmware", operation: operation)
      )
      |> Floki.parse_document!()

    assert Floki.find(other, "#confirm-firmware") == []
  end

  test "firmware builds and destructive bench controls have separate pages" do
    firmware =
      render_component(&DevWeb.FirmwareLive.render/1, assigns()) |> Floki.parse_document!()

    assert Floki.find(firmware, "#build-firmware select[name=target] option[value=ec100]") != []
    assert Floki.find(firmware, "[phx-click=lifecycle], #review-firmware") == []

    simulator =
      render_component(&DevWeb.SimulatorLive.render/1, assigns(confirm_reset: true))
      |> Floki.parse_document!()

    assert Floki.find(simulator, "#simulator-lifecycle #start-devices") != []
    assert Floki.find(simulator, "#confirm-reset #confirm-reset-devices") != []
    assert Floki.text(simulator) =~ "Erase all simulated devices"
    assert Floki.find(simulator, "#review-firmware, #create-application") == []
  end

  test "all pages share one LiveView session and network identities cannot route into simulator details" do
    for {path, view, action} <- [
          {"/", DevWeb.OverviewLive, :overview},
          {"/devices", DevWeb.DevicesLive, :devices},
          {"/devices/physical/ec100.local", DevWeb.PhysicalDeviceLive, :devices},
          {"/devices/gateway_a", DevWeb.DeviceLive, :devices},
          {"/apps", DevWeb.ApplicationsLive, :apps},
          {"/firmware", DevWeb.FirmwareLive, :firmware},
          {"/factory", DevWeb.FactoryLive, :factory},
          {"/simulator", DevWeb.SimulatorLive, :simulator}
        ] do
      route = Phoenix.Router.route_info(DevWeb.Router, "GET", path, "localhost")
      assert {^view, ^action, _, %{name: :workbench}} = route.phoenix_live_view
    end
  end

  defp assigns(extra \\ []),
    do:
      Keyword.merge(
        [
          bench: bench(),
          applications: [],
          images: [],
          discovery: %{status: :idle, devices: [], error: nil},
          operation: operation(),
          error: nil
        ],
        extra
      )

  defp operation, do: %{status: :idle, kind: nil, output: nil, result: nil, review: nil}

  defp bench do
    %{
      blocked: false,
      devices: %{},
      runs: [],
      events: [],
      lifecycle: %{
        status: :stopped,
        phase: "Stopped",
        prepared: false,
        reset_required: false,
        devices: [
          %{id: :gateway_a, address: "127.0.0.2", node: :gateway_a@localhost, internet: :lan1}
        ]
      }
    }
  end
end
