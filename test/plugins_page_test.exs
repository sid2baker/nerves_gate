defmodule WorkbenchWeb.PluginsPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import WorkbenchWeb.PageFixtures

  @plugin %{path: "/projects/demo", name: "demo"}

  test "plugin list creates/opens projects; details own test/package/install" do
    document =
      render_component(
        &WorkbenchWeb.PluginsLive.render/1,
        assigns(plugins: [@plugin], plugin_id: nil, plugin: nil)
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "#create-plugin input[name='plugin[path]']") != []
    assert Floki.find(document, "#open-plugin input[name='plugin[path]']") != []

    assert Floki.attribute(
             document,
             "#firmware-plugin-sources input[name='plugin[path]']",
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
        &WorkbenchWeb.PluginsLive.render/1,
        assigns(plugins: [@plugin], plugin_id: "demo", plugin: @plugin, targets: targets)
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "#plugin-actions button[phx-value-kind=test]") != []

    assert Floki.attribute(document, "#install-plugin select[name=device] option", "value") ==
             ["gateway_a", "nerves_gate@100.64.0.9"]

    assert Floki.find(document, "#create-plugin") == []
  end

  test "a job's output appears only in its own plugin workspace" do
    job = %{job() | kind: "test", status: :failed, result: "Test failed", subject: @plugin.path}
    path = "/develop/plugins/" <> Base.url_encode64(@plugin.path, padding: false)
    assert WorkbenchWeb.Components.job_path(job) == path
    values = assigns(plugins: [@plugin], plugin_id: "demo", plugin: @plugin, job: job)

    document =
      render_component(&WorkbenchWeb.PluginsLive.render/1, values) |> Floki.parse_document!()

    assert Floki.text(Floki.find(document, "#workbench-job")) =~ "Test failed"

    document =
      render_component(
        &WorkbenchWeb.PluginsLive.render/1,
        Keyword.put(values, :plugin, %{@plugin | path: "/other"})
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "#workbench-job") == []
  end
end
