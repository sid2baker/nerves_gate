defmodule WorkbenchWeb.OverviewLive do
  @moduledoc "Resume work and surface actionable workbench problems."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import WorkbenchWeb.Components
  alias Scenarios.Runner

  def mount(_, _, socket) do
    if connected?(socket) do
      Runner.subscribe()
      Workbench.Gateways.subscribe()
    end

    {:ok,
     assign(socket,
       bench: Runner.snapshot(),
       gateways: Workbench.Gateways.list(),
       plugins: Workbench.Plugins.list()
     )}
  end

  def handle_info({:scenarios, bench}, socket), do: {:noreply, assign(socket, :bench, bench)}

  def handle_info({:gateways, gateways}, socket),
    do: {:noreply, assign(socket, :gateways, gateways)}

  def render(assigns) do
    ~H"""
    <main class="ui-main ui-stack bench" id="workbench-overview">
      <.page_header
        eyebrow="Developer workbench"
        title="Home"
        description={"Node #{Node.self()}. Nothing starts, installs or flashes automatically."}
      />
      <.notice :if={@bench.blocked || @bench.lifecycle.reset_required} tone="warning" role="alert">
        The simulated bench needs attention.
        <.link navigate="/develop/firmware#simulator-lifecycle" class="ui-text-link">Inspect QEMU setup and recovery</.link>
      </.notice>
      <.panel :if={@job.kind} title="Current job" icon="clock">
        <.job job={@job} />
        <.link navigate={job_path(@job)} class="ui-text-link">Continue</.link>
      </.panel>
      <.panel title="Gateways" icon="network" id="home-gateways">
        <p :if={@gateways == []} class="ui-help">No gateways connected yet.</p>
        <.setting_row :for={gateway <- @gateways} label={to_string(gateway.node)}>
          <.device_kind source={gateway.source} />
          <.connection gateway={gateway} />
          <.link navigate={"/devices/#{gateway.node}"} class="ui-text-link">Open</.link>
        </.setting_row>
      </.panel>
      <.panel title="Resume work" icon="display" id="resume-work">
        <.setting_row :for={plugin <- @plugins} label={plugin.name}>
          <.link
            navigate={"/develop/plugins/#{Base.url_encode64(plugin.path, padding: false)}"}
            class="ui-text-link"
          >{plugin.path}</.link>
        </.setting_row>
        <.link
          :for={run <- @bench.runs}
          navigate="/develop/firmware#lab-runs"
          class="ui-text-link"
        >Run #{run.id} · {run.device} · {run.status}</.link>
        <.link navigate="/develop/plugins" class="ui-text-link">Create or open a plugin</.link>
      </.panel>
      <div class="dev-summary-grid">
        <.link navigate="/develop/firmware" class="dev-summary-card"><h2>Build and test firmware</h2><p>
          Build an image, run QEMU, test and debug.
        </p></.link>
        <.link navigate="/develop/plugins" class="dev-summary-card"><h2>
          Develop a plugin
        </h2><p>Test, package and run on a simulated device.</p></.link>
        <.link navigate="/devices" class="dev-summary-card"><h2>Gateways</h2><p>
          Status, checks and reviewed updates.
        </p></.link>
        <.link navigate="/provision" class="dev-summary-card"><h2>Provision a new EC100</h2><p>
          Factory USB installation.
        </p></.link>
      </div>
    </main>
    """
  end
end
