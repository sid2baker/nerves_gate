defmodule WorkbenchWeb.OverviewLive do
  @moduledoc "Resume work and surface actionable workbench problems."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import WorkbenchWeb.Components
  alias Scenarios.Runner

  def mount(_, _, socket) do
    if connected?(socket) do
      Runner.subscribe()
      Process.send_after(self(), :overview, 1_000)
    end

    {:ok, refresh(socket)}
  end

  def handle_info(:overview, socket) do
    Process.send_after(self(), :overview, 1_000)
    {:noreply, refresh(socket)}
  end

  def handle_info({:scenarios, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket),
    do: assign(socket, bench: Runner.snapshot(), applications: Workbench.Applications.list())

  def render(assigns) do
    ~H"""
    <main class="ui-main ui-stack bench" id="workbench-overview">
      <.page_header
        eyebrow="Developer workbench"
        title="Home"
        description="Pick up your work. Nothing starts, installs or flashes automatically."
      />
      <.notice :if={@bench.blocked || @bench.lifecycle.reset_required} tone="warning" role="alert">
        The test bench needs attention before more work can run.
        <.link navigate="/develop/firmware#simulator-lifecycle" class="ui-text-link">Inspect QEMU setup and recovery</.link>
      </.notice>
      <.panel :if={@operation.kind} title="Current operation" icon="clock">
        <.status tone={result_tone(@operation.status)}>
          {operation_label(@operation.kind)} · {@operation.status}
        </.status>
        <p :if={@operation.result}>{@operation.result}</p>
        <.link navigate={operation_path(@operation)} class="ui-text-link">Continue to operation and output</.link>
      </.panel>
      <.panel title="Resume work" icon="equipment" id="resume-work">
        <p :if={@applications == []} class="ui-help">
          Open an application to begin a test, package and run loop.
        </p>
        <.setting_row :for={app <- @applications} label={app.name}>
          <.link
            navigate={"/develop/applications/#{Base.url_encode64(app.path, padding: false)}"}
            class="ui-text-link"
          >{app.path}</.link>
        </.setting_row>
        <.link navigate="/develop/applications" class="ui-text-link">Create or open an application</.link>
        <.link
          :for={run <- @bench.runs}
          navigate={"/develop/firmware/scenarios/#{run.device}"}
          class="ui-text-link"
        >
          Run #{run.id} · {run.device} · {run.status}
        </.link>
      </.panel>
      <div class="dev-summary-grid">
        <.link navigate="/develop/firmware" class="dev-summary-card"><h2>Build and test firmware</h2><p>
          Build an image, set up QEMU, run scenarios and debug in one workspace.
        </p></.link>
        <.link navigate="/develop/applications" class="dev-summary-card"><h2>
          Develop an application
        </h2><p>
          Open a project, test and package it, then run on a selected device.
        </p></.link>
        <.link navigate="/devices" class="dev-summary-card"><h2>Inspect or update a gateway</h2><p>
          Find physical and simulated devices, diagnostics and reviewed SSH updates.
        </p></.link>
        <.link navigate="/provision" class="dev-summary-card"><h2>Provision a new EC100</h2><p>
          Guarded factory USB installation, separate from routine updates.
        </p></.link>
      </div>
    </main>
    """
  end
end
