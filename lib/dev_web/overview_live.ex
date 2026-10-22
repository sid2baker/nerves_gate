defmodule DevWeb.OverviewLive do
  @moduledoc "Small workbench landing page. Configuration and commands live on their own pages."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import DevWeb.Components
  alias NervesGateSim.QemuTests

  def mount(_, _, socket) do
    if connected?(socket) do
      QemuTests.subscribe()
      Process.send_after(self(), :overview, 1_000)
    end

    {:ok, refresh(socket)}
  end

  def handle_info(:overview, socket) do
    Process.send_after(self(), :overview, 1_000)
    {:noreply, refresh(socket)}
  end

  def handle_info({:qemu_tests, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket),
    do:
      assign(socket,
        bench: QemuTests.snapshot(),
        applications: Dev.Applications.list(),
        discovery: Dev.Discovery.snapshot()
      )

  def render(assigns) do
    ~H"""
    <main class="ui-main ui-stack bench" id="workbench-overview">
      <.page_header
        eyebrow="Developer workbench"
        title="Overview"
        description="Develop applications, inspect devices and build firmware. Nothing starts or flashes automatically."
      />
      <div class="dev-summary-grid">
        <.link navigate="/devices" class="dev-summary-card"><.icon name="network" /><h2>Devices</h2><p>
          {length(@discovery.devices)} physical entries · {length(@bench.lifecycle.devices)} simulated
        </p></.link>
        <.link navigate="/apps" class="dev-summary-card"><.icon name="equipment" /><h2>
          Applications
        </h2><p>{length(@applications)} open projects</p></.link>
        <.link navigate="/simulator" class="dev-summary-card"><.icon name="settings" /><h2>
          Simulator
        </h2><p>{@bench.lifecycle.phase}</p></.link>
        <.link navigate="/firmware" class="dev-summary-card"><.icon name="port" /><h2>Firmware</h2><p>
          EC100 and QEMU builds
        </p></.link>
      </div>
      <.notice :if={@bench.blocked} tone="warning" role="alert">
        Simulator state is uncertain. Inspect diagnostics and recovery on the <.link
          navigate="/simulator"
          class="ui-text-link"
        >Simulator page</.link>.
      </.notice>
      <.panel title="Current operation" icon="clock">
        <.operation operation={@operation} /><.link
          :if={@operation.kind}
          navigate={operation_path(@operation)}
          class="ui-text-link"
        >Open operation context</.link>
      </.panel>
      <p class="ui-help">
        Discovered devices are unverified. A physical gateway never receives QEMU lifecycle or fault controls.
      </p>
    </main>
    """
  end
end
