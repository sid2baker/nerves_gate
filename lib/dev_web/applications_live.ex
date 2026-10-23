defmodule DevWeb.ApplicationsLive do
  @moduledoc "Ordinary SDK projects, with per-application test, package and installation actions."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import DevWeb.Components
  alias Simulator.QemuTests

  def mount(_, _, socket) do
    if connected?(socket) do
      QemuTests.subscribe()
      Process.send_after(self(), :applications, 1_000)
    end

    {:ok, socket |> assign(app_id: nil) |> refresh()}
  end

  def handle_params(params, _, socket),
    do: {:noreply, socket |> assign(:app_id, params["id"]) |> refresh()}

  def handle_event(action, %{"application" => %{"path" => path}}, socket)
      when action in ["create_application", "open_application"] do
    kind = if action == "create_application", do: "new", else: "open"
    command(socket, Dev.Workbench.application(kind, path))
  end

  def handle_event("operation", params, socket) do
    case socket.assigns.app do
      nil -> command(socket, {:error, "Open an application first"})
      app -> command(socket, Dev.Workbench.operate(params["kind"], app.path, params["device"]))
    end
  end

  def handle_info(:applications, socket) do
    Process.send_after(self(), :applications, 1_000)
    {:noreply, refresh(socket)}
  end

  def handle_info({:qemu_tests, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    apps = Dev.Applications.list()
    app = Enum.find(apps, &(id(&1.path) == socket.assigns.app_id))
    assign(socket, applications: apps, app: app, bench: QemuTests.snapshot())
  end

  defp command(socket, :ok),
    do:
      {:noreply, socket |> assign(error: nil, operation: Dev.Operations.snapshot()) |> refresh()}

  defp command(socket, {:error, message}), do: {:noreply, assign(socket, :error, message)}
  defp id(path), do: Base.url_encode64(path, padding: false)

  def render(assigns) do
    ~H"""
    <main class="ui-main ui-stack bench" id="applications-page">
      <.back_link :if={@app_id} navigate="/apps">Applications</.back_link>
      <.page_header
        eyebrow="Developer workbench"
        title={if @app, do: @app.name, else: "Applications"}
        description={if @app, do: @app.path, else: "Ordinary SDK projects in their own directories."}
      />
      <.notice :if={@app_id && !@app} tone="warning">
        Application is not open in this session.
      </.notice>
      <.panel :if={!@app_id} title="Create or open an application" icon="equipment">
        <form id="create-application" phx-submit="create_application" class="ui-actions">
          <input
            type="text"
            name="application[path]"
            aria-label="New application directory"
            placeholder="../my_controller"
            required
          />
          <.button type="submit">Create application</.button>
        </form>
        <form id="open-application" phx-submit="open_application" class="ui-actions">
          <input
            type="text"
            name="application[path]"
            aria-label="Existing application directory"
            placeholder="/home/me/projects/my_controller"
            required
          />
          <.button type="submit" variant="secondary">Open application</.button>
        </form>
        <p class="ui-help">
          No solution or workspace manifest. Opened projects are remembered for this workbench session; their code runs only in isolated processes.
        </p>
      </.panel>
      <.panel :if={!@app_id} title="Open applications" icon="equipment" id="applications">
        <p :if={@applications == []} class="ui-help">
          No applications open. Create or open one above.
        </p>
        <div :for={app <- @applications} class="ui-setting-row">
          <div>
            <.link navigate={"/apps/#{id(app.path)}"} class="ui-text-link">{app.name}</.link><p class="ui-help">
              {app.path}
            </p>
          </div>
        </div>
      </.panel>
      <.panel :if={@app} title="Application actions" icon="check" id="application-actions">
        <div class="ui-actions">
          <.button
            :for={kind <- ["test", "package"]}
            phx-click="operation"
            phx-value-kind={kind}
            disabled={@operation.status == :running}
          >{String.capitalize(kind)}</.button>
        </div>
        <form id="install-application" phx-submit="operation" class="ui-actions">
          <input type="hidden" name="kind" value="install" />
          <select name="device" aria-label={"Install #{@app.name} on simulated device"}>
            <option :for={device <- @bench.lifecycle.devices} value={device.id}>
              {device.id} · Simulated
            </option>
          </select>
          <.button
            type="submit"
            disabled={@operation.status == :running || @bench.lifecycle.status != :ready}
          >Install on simulator</.button>
        </form>
        <p class="ui-help">
          Installation uses owned, running QEMU devices and simulator reservations. Physical app installation remains an explicit SSH workflow.
        </p>
      </.panel>
      <.operation operation={@operation} />
    </main>
    """
  end
end
