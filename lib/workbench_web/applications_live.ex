defmodule WorkbenchWeb.ApplicationsLive do
  @moduledoc "Ordinary SDK projects, with per-application test, package and installation actions."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import WorkbenchWeb.Components
  alias Scenarios.Runner

  def mount(_, _, socket) do
    if connected?(socket) do
      Runner.subscribe()
      Process.send_after(self(), :applications, 1_000)
    end

    {:ok, socket |> assign(app_id: nil) |> refresh()}
  end

  def handle_params(params, _, socket),
    do: {:noreply, socket |> assign(:app_id, params["id"]) |> refresh()}

  def handle_event(action, %{"application" => %{"path" => path}}, socket)
      when action in ["create_application", "open_application"] do
    result =
      if action == "create_application",
        do: Workbench.Applications.create(path),
        else: Workbench.Applications.open(path)

    case result do
      {:ok, app} ->
        {:noreply, push_navigate(socket, to: "/develop/applications/#{id(app.path)}")}

      error ->
        command(socket, error)
    end
  end

  def handle_event("operation", params, socket) do
    case socket.assigns.app do
      nil ->
        command(socket, {:error, "Open an application first"})

      app ->
        command(socket, Workbench.Operations.start(params["kind"], app.path, params["device"]))
    end
  end

  def handle_event(
        "review_physical_install",
        %{"address" => address},
        %{assigns: %{app: app}} = socket
      )
      when not is_nil(app),
      do: command(socket, Workbench.Operations.review_app_install(app.path, address))

  def handle_event(
        "confirm_physical_install",
        %{"review_id" => token, "address" => address},
        %{assigns: %{app: app}} = socket
      )
      when not is_nil(app),
      do: command(socket, Workbench.Operations.confirm_app_install(token, address, app.path))

  def handle_event(event, _, socket)
      when event in ["review_physical_install", "confirm_physical_install"],
      do: command(socket, {:error, "Open an application first"})

  def handle_info(:applications, socket) do
    Process.send_after(self(), :applications, 1_000)
    {:noreply, refresh(socket)}
  end

  def handle_info({:scenarios, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    apps = Workbench.Applications.list()
    app = Enum.find(apps, &(id(&1.path) == socket.assigns.app_id))

    assign(socket,
      applications: apps,
      app: app,
      bench: Runner.snapshot(),
      physical_devices: Workbench.LANDiscovery.snapshot().devices
    )
  end

  defp command(socket, {:ok, _}), do: command(socket, :ok)

  defp command(socket, :ok),
    do:
      {:noreply,
       socket |> assign(error: nil, operation: Workbench.Operations.snapshot()) |> refresh()}

  defp command(socket, {:error, message}), do: {:noreply, assign(socket, :error, message)}
  defp id(path), do: Base.url_encode64(path, padding: false)

  def render(assigns) do
    assigns = assign(assigns, :physical_devices, Map.get(assigns, :physical_devices, []))

    ~H"""
    <main class="ui-main ui-stack bench" id="applications-page">
      <.back_link :if={@app_id} navigate="/develop/applications">Applications</.back_link>
      <.page_header
        eyebrow="Develop · Applications"
        title={if @app, do: @app.name, else: "Applications"}
        description={if @app, do: @app.path, else: "Ordinary SDK projects in their own directories."}
      />
      <.develop_navigation section={:apps} />
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
      <.panel
        :if={!@app_id}
        title="Starter app · Tailnet subnet router"
        icon="network"
        id="starter-tailnet-subrouter"
      >
        <p>
          Optional SDK application: use an enabled Ethernet interface to expose one local subnet through the gateway's enrolled tailnet. Starts disabled; opening, testing or packaging never enables routing.
        </p>
        <form phx-submit="open_application">
          <input
            type="hidden"
            name="application[path]"
            value={Path.join(Workbench.root(), "apps/tailnet_subrouter")}
          />
          <.button type="submit" variant="secondary">Open starter app source</.button>
        </form>
        <p class="ui-help">
          Configure and enable explicitly through the app's API after installation. See apps/tailnet_subrouter/README.md. This is not a built-in gateway service.
        </p>
      </.panel>
      <.panel :if={!@app_id} title="Open applications" icon="equipment" id="applications">
        <p :if={@applications == []} class="ui-help">
          No applications open. Create or open one above.
        </p>
        <div :for={app <- @applications} class="ui-setting-row">
          <div>
            <.link navigate={"/develop/applications/#{id(app.path)}"} class="ui-text-link">{app.name}</.link><p class="ui-help">
              {app.path}
            </p>
          </div>
        </div>
      </.panel>
      <.panel :if={@app} title="Test, package and run" icon="check" id="application-actions">
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
          >Install and run on simulator</.button>
        </form>
        <p class="ui-help">
          Simulator installation uses owned, running QEMU devices and reservations. Physical installations below use a separate reviewed SSH procedure and never start the app.
        </p>
      </.panel>
      <.panel :if={@app} title="Install on physical device" icon="network" id="physical-app-install">
        <p>
          Build a private package snapshot, verify the device over known-host/public-key SSH, and review before sending anything. Requires prepared application storage and firmware supporting reviewed installation.
        </p>
        <form id="review-physical-install" phx-submit="review_physical_install" class="ui-stack">
          <label>Physical gateway<select name="address" required>
            <option :for={device <- @physical_devices} value={device.address}>
              {device.address} · {device[:serial] || "Verify identity during review"}
            </option>
          </select></label>
          <.button type="submit" disabled={@operation.status == :running || @physical_devices == []}>Review package and device</.button>
        </form>
        <.link :if={@physical_devices == []} navigate="/devices?kind=physical" class="ui-text-link">Find or add a physical gateway first</.link>
        <.notice
          :if={
            @operation.review && @operation.review[:kind] == :app_install &&
              @operation.review.project == @app.path
          }
          tone="warning"
          id="physical-install-review"
        >
          <p>
            Install {@operation.review.app} {@operation.review.version} on {@operation.review.address} · serial {@operation.review.serial} · {@operation.review.target} · firmware {@operation.review.firmware}.
          </p>
          <p>
            SDK requirement: {@operation.review.sdk_requirement} · package {@operation.review.bytes} bytes
          </p>
          <code>SHA-256: {@operation.review.sha256}</code>
          <p>
            Expires after ten minutes and is consumed once. Installs a new stopped, disabled application only—no start, upgrade, firmware update or route advertisement. Existing installations are rejected.
          </p>
          <form id="confirm-physical-install" phx-submit="confirm_physical_install" class="ui-stack">
            <input type="hidden" name="review_id" value={@operation.review.token} />
            <input
              type="text"
              name="address"
              placeholder={@operation.review.address}
              aria-label="Confirm physical install address"
              required
              autocomplete="off"
            />
            <.button type="submit" variant="danger" disabled={@operation.status == :running}>Install reviewed app · leave stopped</.button>
          </form>
        </.notice>
        <p class="ui-help">
          Installation writes application storage. If a reply is lost, inspect the device before any retry. Installation cannot be cancelled or replayed automatically. Starting an app is a separate deliberate device-side action.
        </p>
      </.panel>
      <.panel
        :if={@app && operation_path(@operation) == "/develop/applications/#{id(@app.path)}"}
        title="Result and output"
        icon="clock"
      >
        <.operation operation={@operation} />
      </.panel>
      <.panel :if={@app} title="Choose where to run" icon="network">
        <p>
          <.link navigate="/develop/firmware#simulator-lifecycle" class="ui-text-link">Set up QEMU</.link>
          to install and run the application above, then <.link
            navigate="/develop/firmware#lab-devices"
            class="ui-text-link"
          >test or debug the device</.link>.
        </p>
        <p>
          For physical hardware, select a discovered gateway above, review the package/device, then type its exact address to confirm installation. The application remains stopped and disabled; starting or configuring it remains a separate explicit action.
        </p>
        <.link navigate="/devices?kind=physical" class="ui-text-link">Find a physical gateway</.link>
      </.panel>
    </main>
    """
  end
end
