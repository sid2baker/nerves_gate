defmodule DevWeb.WorkbenchPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]

  test "solution apps expose test, package and selected-device installation" do
    html = page(%{path: "/solutions/demo", platform: Dev.version(), warning: nil, apps: ["demo"]})
    document = Floki.parse_document!(html)
    assert Floki.find(document, "#app-demo button[phx-value-kind=test]") != []
    assert Floki.find(document, "#app-demo button[phx-value-kind=package]") != []
    assert Floki.find(document, "#app-demo form input[name=kind][value=install]") != []
    assert Floki.find(document, "#app-demo form select[name=device]") != []
    assert html =~ "/solutions/demo"
    assert Floki.find(document, "#workbench-operation button[phx-value-kind=firmware]") != []
  end

  test "an empty workbench explains solution creation without app actions" do
    html = page(nil)
    assert html =~ "mix solution.new PATH"
    assert Floki.find(Floki.parse_document!(html), "button[phx-value-kind=test]") == []
  end

  defp page(solution) do
    render_component(&DevWeb.OverviewLive.render/1,
      solution: solution,
      operation: %{status: :idle, kind: nil, output: nil, result: nil},
      error: nil,
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
