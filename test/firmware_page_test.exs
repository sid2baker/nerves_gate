defmodule WorkbenchWeb.FirmwarePageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import WorkbenchWeb.PageFixtures

  defp gateway_page(gateway, extra \\ []) do
    render_component(
      &WorkbenchWeb.GatewayLive.render/1,
      assigns(
        [
          node: to_string(gateway.node),
          gateway: gateway,
          tab: :devices,
          projection: NervesGate.Projection.disconnected().status,
          sim_id: gateway.sim_id,
          device: nil,
          active: nil,
          results: %{},
          confirm_run: nil
        ] ++ extra
      )
    )
    |> Floki.parse_document!()
  end

  test "physical gateway: firmware review needs an image and confirmation binds the review" do
    empty = gateway_page(gateway())
    assert Floki.find(empty, "#review-firmware select[disabled]") != []
    assert Floki.find(empty, "#review-firmware button[type=submit][disabled]") != []
    assert Floki.find(empty, "#physical-checks [phx-click=check]") |> length() == 3
    assert Floki.find(empty, "#scenarios, #manual-controls") == []

    images = [%{path: "/built/ec100.fw", version: "0.2.0-dev", build: "ec100_dev/nerves_gate.fw"}]

    review = %{
      kind: :firmware,
      token: "one-use",
      node: gateway().node,
      address: gateway().address,
      current_version: "0.1.0",
      version: "0.2.0-dev",
      serial: "board-42",
      source_revision: String.duplicate("a", 40),
      sha256: "reviewed-hash"
    }

    job = %{
      job()
      | kind: "firmware_review",
        subject: gateway().node,
        status: :awaiting_confirmation,
        review: review
    }

    document = gateway_page(gateway(), images: images, job: job)

    assert Floki.find(document, "select[name=firmware] option[value='/built/ec100.fw']") != []

    assert Floki.attribute(document, "#confirm-firmware input[name=review_id]", "value") == [
             "one-use"
           ]

    assert Floki.text(document) =~ "reviewed-hash"
  end

  test "simulated gateway: bench panels instead of physical checks and updates" do
    simulated = gateway(%{node: :"nerves_gate@10.203.42.2", source: :qemu, sim_id: :gateway_a})
    document = gateway_page(simulated)
    assert Floki.find(document, "#physical-checks, #firmware-update") == []
    assert Floki.find(document, "#device-not-running") != []

    assert Floki.attribute(document, "nav[aria-label='Device sections'] a", "href") |> length() ==
             3
  end

  test "firmware workspace keeps build, QEMU setup, test entry points and results together" do
    firmware =
      render_component(&WorkbenchWeb.FirmwareLive.render/1, assigns(confirm_reset: false))
      |> Floki.parse_document!()

    assert Floki.find(firmware, "#build-firmware select[name=target] option[value=ec100]") != []
    assert Floki.find(firmware, "#simulator-lifecycle #start-devices") != []

    assert Floki.find(
             firmware,
             "#lab-devices a[href='/devices/nerves_gate@10.203.42.2/scenarios']"
           ) != []

    assert Floki.find(firmware, "#lab-devices a[href='/devices/nerves_gate@10.203.42.2/manual']") !=
             []

    assert Floki.find(firmware, "#lab-runs") != []

    confirmation =
      render_component(&WorkbenchWeb.FirmwareLive.render/1, assigns(confirm_reset: true))
      |> Floki.parse_document!()

    assert Floki.find(confirmation, "#confirm-reset #confirm-reset-devices") != []
  end
end
