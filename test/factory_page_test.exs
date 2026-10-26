defmodule WorkbenchWeb.FactoryPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import WorkbenchWeb.PageFixtures

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
end
