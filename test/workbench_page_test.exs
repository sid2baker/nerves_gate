defmodule DevWeb.WorkbenchPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]

  test "ordinary applications expose test, package and simulator installation" do
    html = page([%{path: "/projects/demo", name: "demo"}])
    document = Floki.parse_document!(html)
    assert Floki.find(document, "#applications button[phx-value-kind=test]") != []
    assert Floki.find(document, "#applications button[phx-value-kind=package]") != []

    assert Floki.find(document, "#applications form input[name=app][value='/projects/demo']") !=
             []

    assert html =~ "/projects/demo"
    assert Floki.find(document, "#workbench-operation select[name=app] option[value=ec100]") != []
    assert Floki.find(document, "#review-firmware input[name=address]") != []
  end

  test "plain workbench offers LAN discovery and app creation/opening without a solution" do
    document = page([]) |> Floki.parse_document!()
    assert Floki.find(document, "#create-application input[name='application[path]']") != []
    assert Floki.find(document, "#open-application input[name='application[path]']") != []
    assert Floki.find(document, "#network-devices button[phx-click=discover]") != []
    assert Floki.find(document, "#add-address input[name=address]") != []
    assert Floki.find(document, "button[phx-value-kind=test]") == []
  end

  test "physical update shows the reviewed host/image and requires explicit typed confirmation" do
    review = %{
      address: "ec100.example.ts.net",
      port: 22,
      target: "ec100",
      current_version: "0.1.0",
      version: "0.2.0-dev",
      serial: "controller",
      firmware: "/images/ec100.fw",
      sha256: String.duplicate("a", 64),
      token: "review-id"
    }

    document = page([], review) |> Floki.parse_document!()

    assert Floki.find(
             document,
             "#firmware-confirmation form[phx-submit=confirm_firmware] input[name=address][required]"
           ) != []

    assert Floki.find(document, "#firmware-confirmation input[name=review_id][value=review-id]") !=
             []

    assert Floki.text(document) =~ "Update firmware and reboot"
    assert Floki.text(document) =~ "ec100.example.ts.net"
    assert Floki.text(document) =~ "SHA-256"
  end

  defp page(applications, review \\ nil) do
    render_component(&DevWeb.OverviewLive.render/1,
      applications: applications,
      discovery: %{status: :idle, devices: [], error: nil},
      operation: %{status: :idle, kind: nil, output: nil, result: nil, review: review},
      error: nil,
      update_address: "",
      confirm_reset: false,
      bench: %{
        blocked: false,
        devices: %{},
        runs: [],
        events: [],
        lifecycle: %{
          status: :stopped,
          phase: "Stopped",
          prepared: false,
          reset_required: false,
          devices: []
        }
      }
    )
  end
end
