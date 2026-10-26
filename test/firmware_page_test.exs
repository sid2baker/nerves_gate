defmodule WorkbenchWeb.FirmwarePageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import WorkbenchWeb.PageFixtures

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
end
