defmodule WorkbenchWeb.PhysicalDevicePageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import WorkbenchWeb.PageFixtures

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

  test "hardware tests and device procedures are separate, explicit physical workflows" do
    {:ok, device} = Workbench.LANDiscovery.manual("172.31.211.1")

    document =
      render_component(
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
        assigns(device: device, tab: "tests")
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "#hardware-test select[name=profile] option") |> length() == 3
    assert Floki.text(document) =~ "does not prove cable-loss takeover"

    assert Floki.find(document, "#review-firmware, #confirm-firmware, [phx-click=lifecycle]") ==
             []

    document =
      render_component(
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
        assigns(device: device, tab: "firmware")
      )
      |> Floki.parse_document!()

    assert Floki.attribute(document, "select[name=verify_usb] option:first-child", "value") == [
             "ssh"
           ]

    assert Floki.find(document, "#review-reboot select[name=management] option[value=ssh]") != []
    assert Floki.find(document, "#review-reboot select[name=management] option[value=usb]") != []

    assert Floki.text(document) =~ "Verification failure does not upload again"
    assert Floki.find(document, "#hardware-test") == []
  end

  test "assisted failover requires cellular consent and exposes cancellation only for its running observer" do
    {:ok, device} = Workbench.LANDiscovery.manual("172.31.211.1")

    operation =
      Map.merge(operation(), %{
        kind: "hardware_failover",
        status: :running,
        context: %{subject: device.address}
      })

    document =
      render_component(
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
        assigns(device: device, tab: "tests", operation: operation)
      )
      |> Floki.parse_document!()

    assert Floki.find(
             document,
             "#hardware-failover-test input[name=consent][type=checkbox][required]"
           ) != []

    assert Floki.find(document, "#hardware-failover-test button[disabled]") != []
    assert Floki.find(document, "#hardware-failover button[phx-click=cancel_observation]") != []
    assert Floki.text(document) =~ "no automatic cable restoration"
    operation = %{operation | kind: "firmware_update"}

    document =
      render_component(
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
        assigns(device: device, tab: "tests", operation: operation)
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "button[phx-click=cancel_observation]") == []
  end

  test "procedures keep reboot observation reviews apart from firmware writes and reset is guidance only" do
    {:ok, device} = Workbench.LANDiscovery.manual("172.31.211.1")

    review = %{
      kind: :reboot,
      address: device.address,
      version: "new",
      serial: "device-42",
      management: "usb0",
      token: "reboot-review"
    }

    operation = %{operation() | review: review}

    document =
      render_component(
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
        assigns(device: device, tab: "firmware", operation: operation)
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "#confirm-reboot input[name=address][required]") != []

    assert Floki.find(document, "#confirm-reboot input[name=review_id][value=reboot-review]") !=
             []

    assert Floki.find(document, "#confirm-firmware") == []
    assert Floki.find(document, "#device-reset button, #device-reset form") == []
    assert Floki.find(document, "#physical-device a[href='/provision']") == []
    assert Floki.text(document) =~ "no remote reboot command"
    assert Floki.find(document, "#device-setup a[href='http://172.31.211.1:4000/network']") != []
    other = %{device | address: "other"}

    document =
      render_component(
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
        assigns(device: other, tab: "firmware", operation: operation)
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "#confirm-reboot") == []
  end

  test "diagnostics display the sanitized report beside their device's procedures" do
    {:ok, device} = Workbench.LANDiscovery.manual("172.31.211.1")

    operation =
      Map.merge(operation(), %{
        kind: "hardware_diagnostics",
        status: :succeeded,
        context: %{subject: device.address},
        diagnostic_report: %{device: %{"target" => "ec100"}}
      })

    document =
      render_component(
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
        assigns(device: device, tab: "firmware", operation: operation)
      )
      |> Floki.parse_document!()

    assert Floki.text(Floki.find(document, "#device-diagnostics #hardware-diagnostic-report")) =~
             "ec100"

    assert WorkbenchWeb.Components.operation_path(operation) ==
             Workbench.Devices.physical_path(device.address) <> "?tab=firmware"
  end

  test "remote update verification is explicitly reviewed without claiming independent USB" do
    review = %{
      address: "device.example.ts.net",
      port: 22,
      target: "ec100",
      current_version: "old",
      source_revision: String.duplicate("a", 40),
      version: "new",
      serial: "device-42",
      firmware: "/image.fw",
      sha256: "sha",
      token: "review",
      verify_usb: false,
      verify_ssh: true
    }

    document =
      render_component(&WorkbenchWeb.Components.firmware_confirmation/1, review: review)
      |> Floki.parse_document!()

    assert Floki.text(document) =~ "SSH update-and-verify procedure"
    assert Floki.text(document) =~ "Update, reboot and verify over SSH"
    refute Floki.text(document) =~ "USB update-and-verify procedure"
    assert Floki.find(document, "#confirm-firmware input[name=address][required]") != []
  end

  test "physical readiness results retain profile, target and failure details" do
    {:ok, device} = Workbench.LANDiscovery.manual("172.31.211.1")

    operation =
      Map.merge(operation(), %{
        kind: "hardware_test",
        status: :failed,
        context: %{subject: device.address},
        checks: %{
          profile: "backup",
          observed: %{
            "mode" => "backup",
            "selected" => "ethernet",
            "ethernet" => "internet",
            "cellular" => "internet",
            "health" => "online"
          },
          rows: [
            %{
              id: "hardware_readiness",
              status: :failed,
              detail: "Backup cellular Internet is not ready"
            }
          ]
        }
      })

    document =
      render_component(
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
        assigns(device: device, tab: "tests", operation: operation)
      )
      |> Floki.parse_document!()

    assert Floki.text(document) =~ "Read-only readiness profile: backup"

    assert Floki.text(Floki.find(document, "#hardware-observed-network")) =~
             "Observed profile: backup"

    assert Floki.text(Floki.find(document, "#hardware-tests #hardware-check-results")) =~
             "Backup cellular Internet is not ready"

    assert WorkbenchWeb.Components.operation_path(operation) ==
             Workbench.Devices.physical_path(device.address) <> "?tab=tests"
  end

  test "physical review stays on its selected device and typed confirmation never leaks to another device" do
    {:ok, device} = Workbench.LANDiscovery.manual("ec100.example.ts.net")

    review = %{
      address: device.address,
      port: 22,
      target: "ec100",
      current_version: "0.1.0",
      source_revision: String.duplicate("a", 40),
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
end
