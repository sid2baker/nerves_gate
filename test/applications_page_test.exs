defmodule WorkbenchWeb.ApplicationsPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import WorkbenchWeb.PageFixtures

  @app %{path: "/projects/demo", name: "demo"}

  test "application list creates/opens projects; details own test/package/install" do
    document =
      render_component(
        &WorkbenchWeb.ApplicationsLive.render/1,
        assigns(applications: [@app], app_id: nil, app: nil)
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

    assert Floki.find(document, "button[phx-value-kind=test]") == []

    targets = [
      {"gateway_a", "gateway_a · simulated"},
      {"nerves_gate@100.64.0.9", "nerves_gate@100.64.0.9 · physical"}
    ]

    document =
      render_component(
        &WorkbenchWeb.ApplicationsLive.render/1,
        assigns(applications: [@app], app_id: "demo", app: @app, targets: targets)
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "#application-actions button[phx-value-kind=test]") != []

    assert Floki.attribute(document, "#install-application select[name=device] option", "value") ==
             ["gateway_a", "nerves_gate@100.64.0.9"]

    assert Floki.find(document, "#create-application") == []
  end

  test "a job's output appears only in its own application workspace" do
    job = %{job() | kind: "test", status: :failed, result: "Test failed", subject: @app.path}
    path = "/develop/applications/" <> Base.url_encode64(@app.path, padding: false)
    assert WorkbenchWeb.Components.job_path(job) == path
    values = assigns(applications: [@app], app_id: "demo", app: @app, job: job)

    document =
      render_component(&WorkbenchWeb.ApplicationsLive.render/1, values) |> Floki.parse_document!()

    assert Floki.text(Floki.find(document, "#workbench-job")) =~ "Test failed"

    document =
      render_component(
        &WorkbenchWeb.ApplicationsLive.render/1,
        Keyword.put(values, :app, %{@app | path: "/other"})
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "#workbench-job") == []
  end
end
