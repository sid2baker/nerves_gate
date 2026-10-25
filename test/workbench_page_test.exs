defmodule WorkbenchWeb.WorkbenchPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]

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

  test "tailnet candidates open their HTTPS endpoint without pretending SSH identity was read" do
    [device] =
      Workbench.LANDiscovery.tailnet_devices(%{
        "Peer" => %{"a" => %{"DNSName" => "nerves-gate.tail40465.ts.net.", "Online" => true}}
      })

    document =
      render_component(
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
        assigns(device: device, tab: "overview")
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "a[href='https://nerves-gate.tail40465.ts.net/'][target=_blank]") !=
             []

    assert Floki.text(document) =~ "Tailnet name"
    assert Floki.text(document) =~ "Not read yet"
  end

  test "application list creates/opens ordinary projects, details own test/package/install" do
    app = %{path: "/projects/demo", name: "demo"}

    document =
      render_component(
        &WorkbenchWeb.ApplicationsLive.render/1,
        assigns(applications: [app], app_id: nil, app: nil)
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "#create-application input[name='application[path]']") != []
    assert Floki.find(document, "#open-application input[name='application[path]']") != []
    assert Floki.find(document, "button[phx-value-kind=test]") == []
    [path] = Floki.attribute(document, "#applications a", "href")
    assert path == "/develop/applications/" <> Base.url_encode64(app.path, padding: false)

    document =
      render_component(
        &WorkbenchWeb.ApplicationsLive.render/1,
        assigns(applications: [app], app_id: "demo", app: app)
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "#application-actions button[phx-value-kind=test]") != []
    assert Floki.find(document, "#application-actions button[phx-value-kind=package]") != []
    assert Floki.find(document, "#install-application select[name=device]") != []
    assert Floki.find(document, "#create-application") == []
  end

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

  test "automatic information progress and retryable failures stay on their device" do
    {:ok, device} = Workbench.LANDiscovery.manual("gateway.example.ts.net")

    for status <- [:reading, :failed] do
      device =
        Map.put(device, :info_read, %{
          status: status,
          message: "SSH connection refused. Check port 22."
        })

      discovery = %{status: :ready, devices: [device], error: nil}
      operation = %{operation() | status: if(status == :reading, do: :running, else: :idle)}

      values =
        assigns(
          discovery: discovery,
          devices: Workbench.Devices.list(bench(), discovery),
          kind: "all",
          query: "",
          operation: operation
        )

      document =
        render_component(&WorkbenchWeb.DevicesLive.render/1, values) |> Floki.parse_document!()

      assert Floki.find(document, "button[phx-click=retry_info]") != [] == (status == :failed)
      if status == :reading, do: assert(Floki.text(document) =~ "Reading information…")

      document =
        render_component(
          &WorkbenchWeb.PhysicalDeviceLive.render/1,
          assigns(device: device, tab: "overview", operation: operation)
        )
        |> Floki.parse_document!()

      assert Floki.find(document, "#device-info-failed") != [] == (status == :failed)

      assert Floki.find(document, "button[phx-click=read_info][disabled]") != [] ==
               (status == :reading)

      if status == :failed, do: assert(Floki.text(document) =~ "Retry information read")
    end
  end

  test "physical review stays on its selected device and typed confirmation never leaks to another device" do
    {:ok, device} = Workbench.LANDiscovery.manual("ec100.example.ts.net")

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
      render_component(&WorkbenchWeb.PhysicalDeviceLive.render/1, values)
      |> Floki.parse_document!()

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
      render_component(
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
        Keyword.put(values, :device, other)
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "#firmware-confirmation") == []
  end

  test "physical overview is read-only and a review links back to its firmware tab" do
    {:ok, device} = Workbench.LANDiscovery.manual("ec100.example.ts.net")
    values = assigns(device: device, tab: "overview")

    document =
      render_component(&WorkbenchWeb.PhysicalDeviceLive.render/1, values)
      |> Floki.parse_document!()

    assert Floki.find(document, "form") == []
    assert Floki.find(document, "button[phx-click=read_info]") != []
    assert Floki.text(document) =~ "Not read yet"
    assert Floki.text(document) =~ "Manually added"

    assert Floki.find(document, "nav[aria-label='Device sections'] a[href$='?tab=firmware']") !=
             []

    assert WorkbenchWeb.Components.operation_path(%{review: %{address: device.address}}) ==
             "/devices/physical/ec100.example.ts.net?tab=firmware"
  end

  test "firmware picker lists image versions and disables review until an image exists" do
    {:ok, device} = Workbench.LANDiscovery.manual("ec100.example.ts.net")
    values = assigns(device: device, tab: "firmware")

    empty =
      render_component(&WorkbenchWeb.PhysicalDeviceLive.render/1, values)
      |> Floki.parse_document!()

    assert Floki.find(empty, "#review-firmware select[disabled]") != []
    assert Floki.find(empty, "#review-firmware button[type=submit][disabled]") != []

    images = [%{path: "/built/ec100.fw", version: "0.2.0-dev", build: "ec100_dev/nerves_gate.fw"}]

    document =
      render_component(
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
        Keyword.put(values, :images, images)
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "select[name=firmware] option[value='/built/ec100.fw']") != []
    assert Floki.text(document) =~ "0.2.0-dev"
    assert Floki.find(document, "#review-firmware button[disabled]") == []
  end

  test "read information only shows whitelisted SSH observations and their timestamp" do
    {:ok, device} = Workbench.LANDiscovery.manual("ec100.example.ts.net")

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
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
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
      topology: %{lan1: :internet, lan2: :equipment},
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
      topology: %{lan1: :internet, lan2: :equipment},
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

  test "operation navigation returns to its exact application workspace and output is not hidden globally" do
    app = %{path: "/projects/demo", name: "demo"}

    operation =
      operation()
      |> Map.merge(%{
        kind: "test",
        status: :failed,
        result: "Test failed",
        context: %{subject: app.path, device: nil}
      })

    path = "/develop/applications/" <> Base.url_encode64(app.path, padding: false)
    assert WorkbenchWeb.Components.operation_path(operation) == path
    values = assigns(applications: [app], app_id: "demo", app: app, operation: operation)

    document =
      render_component(&WorkbenchWeb.ApplicationsLive.render/1, values)
      |> Floki.parse_document!()

    assert Floki.text(Floki.find(document, "#workbench-operation")) =~ "Test failed"

    other = %{app | path: "/projects/other"}

    document =
      render_component(&WorkbenchWeb.ApplicationsLive.render/1, Keyword.put(values, :app, other))
      |> Floki.parse_document!()

    assert Floki.find(document, "#workbench-operation") == []

    document =
      render_component(&WorkbenchWeb.Layouts.app/1,
        operation: operation,
        live_action: :apps,
        error: nil,
        inner_content: Phoenix.HTML.raw("")
      )
      |> Floki.parse_document!()

    assert Floki.attribute(document, "#global-operation", "href") == [path]
    assert Floki.find(document, ".dev-operation-details, #global-operation-output") == []
  end

  test "factory provisioning defaults to backup and binds explicit skipping into review" do
    empty =
      render_component(&WorkbenchWeb.FactoryLive.render/1, assigns()) |> Floki.parse_document!()

    assert Floki.find(empty, "#review-factory select[name=firmware][disabled]") != []
    assert Floki.find(empty, "#confirm-factory") == []
    assert Floki.find(empty, "input[type=password]") == []
    assert Floki.attribute(empty, "#factory-backup option:first-child", "value") == ["true"]
    assert Floki.find(empty, "#factory-backup option[value=false]") != []
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
      render_component(&WorkbenchWeb.FactoryLive.render/1, assigns(operation: operation))
      |> Floki.parse_document!()

    assert Floki.find(
             document,
             "#confirm-factory input[name=identified][type=checkbox][required]"
           ) != []

    assert Floki.find(document, "#confirm-factory input[name=confirmation][required]") != []
    assert Floki.attribute(document, "input[name=review_id]", "value") == ["factory-token"]
    assert Floki.text(document) =~ "ERASE EC100 101"
    assert Floki.text(document) =~ "full eMMC user-area backup"
    assert Floki.text(document) =~ "waits up to three minutes"
    assert WorkbenchWeb.Components.operation_path(operation) == "/provision"

    no_backup =
      Map.merge(review, %{backup_enabled: false, confirmation: "ERASE EC100 101 WITHOUT BACKUP"})

    skipped =
      render_component(
        &WorkbenchWeb.FactoryLive.render/1,
        assigns(operation: %{operation | review: no_backup})
      )
      |> Floki.parse_document!()

    assert Floki.text(skipped) =~ "SKIPPED"
    assert Floki.text(skipped) =~ "No full backup will be made"
    assert Floki.text(skipped) =~ "ERASE EC100 101 WITHOUT BACKUP"
    assert Floki.text(Floki.find(skipped, "#confirm-factory button")) =~ "WITHOUT BACKUP"
    refute Floki.text(skipped) =~ "will be saved before the first write"

    {:ok, device} = Workbench.LANDiscovery.manual("ec100.local")

    other =
      render_component(
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
        assigns(device: device, tab: "firmware", operation: operation)
      )
      |> Floki.parse_document!()

    assert Floki.find(other, "#confirm-firmware") == []
  end

  test "verified flash and USB connection outcomes are shown separately" do
    info = %{
      address: "172.31.210.1",
      interface: "enxusb",
      version: "0.2.0-dev",
      target: "ec100",
      runtime: "Elixir 1.20 · OTP 29",
      read_at: "2026-10-22T12:00:00Z",
      url: "http://172.31.210.1:4000"
    }

    operation =
      %{
        operation()
        | status: :succeeded,
          kind: "factory_provision",
          result: "Factory provisioning verified; device reset."
      }
      |> Map.put(:connection, %{status: :connected, device: info})
      |> Map.put(:recovery, %{backup: "/backups/readbacks", backup_enabled: false})

    connected =
      render_component(&WorkbenchWeb.FactoryLive.render/1, assigns(operation: operation))
      |> Floki.parse_document!()

    assert Floki.text(connected) =~ "Connected over USB"
    assert Floki.text(connected) =~ "Elixir 1.20 · OTP 29"
    assert Floki.text(connected) =~ "not authenticated SSH identity"
    assert Floki.text(connected) =~ "not a backup of the previous firmware/data"
    assert Floki.attribute(connected, "#factory-connected a[target=_blank]", "href") == [info.url]

    timeout = %{
      operation
      | connection: %{
          status: :unavailable,
          message: "Flash verified; USB reconnection not confirmed."
        }
    }

    document =
      render_component(&WorkbenchWeb.FactoryLive.render/1, assigns(operation: timeout))
      |> Floki.parse_document!()

    assert Floki.text(document) =~ "factory" or Floki.text(document) =~ "Factory"
    assert Floki.text(document) =~ "succeeded"

    assert Floki.text(Floki.find(document, "#factory-reconnect-warning")) =~
             "USB reconnection not confirmed"

    assert Floki.find(document, "#factory-connected, #confirm-factory") == []
  end

  test "USB device information is not presented as verified SSH identity" do
    {:ok, device} = Workbench.LANDiscovery.manual("172.31.210.1")

    device =
      Map.merge(device, %{
        source: :usb,
        version: "0.2.0-dev",
        target: "ec100",
        usb_info: %{runtime: "Elixir 1.20 · OTP 29", read_at: "2026-10-22T12:00:00Z"}
      })

    document =
      render_component(
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
        assigns(device: device, tab: "overview")
      )
      |> Floki.parse_document!()

    assert Floki.text(document) =~ "direct USB HTTP"
    assert Floki.text(document) =~ "not authenticated SSH identity"
    assert Floki.text(document) =~ "Elixir 1.20 · OTP 29"
    assert Floki.text(document) =~ "Reviewed USB port"
  end

  test "failed factory review highlights its actual error and explains temporary cleanup" do
    operation = %{
      operation()
      | status: :failed,
        kind: "factory_review",
        output: "Loading the verified review's RAM transport (no eMMC writes)",
        result:
          "The RAM loader opened, but rkdeveloptool could not open or claim the EC100 USB connection."
    }

    document =
      render_component(&WorkbenchWeb.FactoryLive.render/1, assigns(operation: operation))
      |> Floki.parse_document!()

    assert Floki.text(Floki.find(document, "[role=alert]")) =~ "could not open or claim"
    assert Floki.text(document) =~ "temporary files have been removed"
    assert Floki.text(document) =~ "do not copy a temporary loader command"
    assert Floki.find(document, "#confirm-factory") == []
    refute Floki.text(Floki.find(document, ".bench-output")) =~ "rkdeveloptool db"
  end

  test "failed factory provisioning retains a visible recovery backup location" do
    operation =
      %{
        operation()
        | status: :failed,
          kind: "factory_provision",
          result: "Worker exited (epipe). Operation outcome is unknown."
      }
      |> Map.put(:recovery, %{backup: "/backups/owned-recovery"})

    document =
      render_component(&WorkbenchWeb.FactoryLive.render/1, assigns(operation: operation))
      |> Floki.parse_document!()

    assert Floki.text(document) =~ "Preserve recovery files:"
    assert Floki.text(document) =~ "/backups/owned-recovery"
    assert Floki.text(Floki.find(document, "[role=alert]")) =~ "epipe"
    assert Floki.find(document, "#confirm-factory") == []
  end

  test "firmware workspace keeps build, QEMU setup, test entry points and results together" do
    firmware =
      render_component(&WorkbenchWeb.FirmwareLive.render/1, assigns(confirm_reset: false))
      |> Floki.parse_document!()

    assert Floki.find(firmware, "#build-firmware select[name=target] option[value=ec100]") != []
    assert Floki.find(firmware, "#simulator-lifecycle #start-devices") != []

    assert Floki.find(firmware, "#lab-devices a[href='/develop/firmware/scenarios/gateway_a']") !=
             []

    assert Floki.find(firmware, "#lab-devices a[href='/develop/firmware/manual/gateway_a']") != []
    assert Floki.find(firmware, "#lab-runs") != []
    assert Floki.find(firmware, "#confirm-reset, #review-firmware, #create-application") == []

    confirmation =
      render_component(&WorkbenchWeb.FirmwareLive.render/1, assigns(confirm_reset: true))
      |> Floki.parse_document!()

    assert Floki.find(confirmation, "#confirm-reset #confirm-reset-devices") != []
    assert Floki.text(confirmation) =~ "Erase all simulated devices"
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
