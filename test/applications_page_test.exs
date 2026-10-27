defmodule WorkbenchWeb.ApplicationsPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import WorkbenchWeb.PageFixtures

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

    assert Floki.attribute(
             document,
             "#firmware-plugin-sources input[name='application[path]']",
             "value"
           ) ==
             Enum.map(
               ["tailnet_subrouter", "modbus"],
               &Path.join([Workbench.root(), "plugins", &1])
             )

    assert length(
             Floki.find(document, "#firmware-plugin-sources form[phx-submit=open_application]")
           ) == 2

    assert Floki.text(Floki.find(document, "#firmware-plugin-sources")) =~ "Starts disabled"

    assert Floki.find(
             document,
             "#firmware-plugin-sources [phx-submit=operation], #firmware-plugin-sources [phx-click=operation]"
           ) == []

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

  test "physical application install reviews belong to their project and never imply start or upgrade" do
    app = %{path: "/projects/demo", name: "demo"}

    review = %{
      kind: :app_install,
      project: app.path,
      app: "demo",
      version: "1.0.0",
      address: "gateway.example",
      serial: "board-42",
      target: "ec100",
      firmware: "test",
      sdk_requirement: "~> 0.1.0",
      bytes: 1024,
      sha256: "reviewed-hash",
      token: "one-use"
    }

    operation =
      Map.merge(operation(), %{
        kind: "app_install_review",
        status: :awaiting_confirmation,
        review: review,
        context: %{subject: app.path, address: review.address}
      })

    values =
      assigns(
        applications: [app],
        app_id: "demo",
        app: app,
        physical_devices: [%{address: review.address}],
        operation: operation
      )

    document =
      render_component(&WorkbenchWeb.ApplicationsLive.render/1, values) |> Floki.parse_document!()

    assert Floki.attribute(
             document,
             "#review-physical-install select[name=address] option",
             "value"
           ) == [review.address]

    assert Floki.find(document, "#confirm-physical-install input[name=address][required]") != []

    assert Floki.find(document, "#confirm-physical-install input[name=review_id][value=one-use]") !=
             []

    assert Floki.text(Floki.find(document, "#physical-install-review")) =~ "stopped, disabled"

    assert WorkbenchWeb.Components.operation_path(operation) ==
             "/develop/applications/" <> Base.url_encode64(app.path, padding: false)

    other = %{app | path: "/projects/other"}

    document =
      render_component(&WorkbenchWeb.ApplicationsLive.render/1, Keyword.put(values, :app, other))
      |> Floki.parse_document!()

    assert Floki.find(document, "#confirm-physical-install") == []
    {:ok, device} = Workbench.LANDiscovery.manual(review.address)

    document =
      render_component(
        &WorkbenchWeb.PhysicalDeviceLive.render/1,
        assigns(device: device, tab: "firmware", operation: operation)
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "#confirm-firmware, #confirm-physical-install") == []
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
end
