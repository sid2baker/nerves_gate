defmodule WorkbenchWeb.ApplicationsLive do
  @moduledoc "Ordinary SDK projects: test, package, and install on a simulated device or physical gateway."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import WorkbenchWeb.Components
  import WorkbenchWeb.Live, only: [command: 2]

  def mount(_, _, socket) do
    if connected?(socket) do
      Scenarios.Runner.subscribe()
      Workbench.Gateways.subscribe()
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
      {:ok, app} -> {:noreply, push_navigate(socket, to: "/develop/applications/#{id(app.path)}")}
      error -> command(socket, error)
    end
  end

  def handle_event("operation", %{"kind" => kind} = params, %{assigns: %{app: app}} = socket)
      when not is_nil(app) do
    result =
      case kind do
        "test" -> Workbench.Jobs.test_app(app.path)
        "package" -> Workbench.Jobs.package_app(app.path)
        "install" -> Workbench.Jobs.install_app(app.path, params["device"])
      end

    command(socket, result)
  end

  def handle_event("confirm_install", %{"token" => token, "address" => address}, socket),
    do: command(socket, Workbench.Jobs.confirm_app(token, address))

  def handle_event("operation", _, socket),
    do: command(socket, {:error, "Open an application first"})

  def handle_info({:scenarios, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:gateways, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    apps = Workbench.Applications.list()
    bench = Scenarios.Runner.snapshot()

    targets =
      Enum.map(bench.lifecycle.devices, &{to_string(&1.id), "#{&1.id} · simulated"}) ++
        for gateway <- Workbench.Gateways.list(),
            gateway.connected,
            gateway.source == :network,
            do: {to_string(gateway.node), "#{gateway.node} · physical"}

    assign(socket,
      applications: apps,
      app: Enum.find(apps, &(id(&1.path) == socket.assigns.app_id)),
      targets: targets
    )
  end

  defp id(path), do: Base.url_encode64(path, padding: false)

  def render(assigns) do
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
      </.panel>
      <.panel
        :if={!@app_id}
        title="Firmware plugin sources"
        icon="network"
        id="firmware-plugin-sources"
      >
        <form :for={plugin <- ["tailnet_subrouter", "modbus"]} phx-submit="open_application">
          <input
            type="hidden"
            name="application[path]"
            value={Path.join([Workbench.root(), "plugins", plugin])}
          />
          <.button type="submit" variant="secondary">Open {plugin} source</.button>
        </form>
        <p class="ui-help">Change plugins/selection.exs and rebuild firmware to bundle plugins.</p>
      </.panel>
      <.panel :if={!@app_id} title="Open applications" icon="equipment" id="applications">
        <p :if={@applications == []} class="ui-help">No applications open.</p>
        <div :for={app <- @applications} class="ui-setting-row">
          <.link navigate={"/develop/applications/#{id(app.path)}"} class="ui-text-link">{app.name}</.link>
          <p class="ui-help">{app.path}</p>
        </div>
      </.panel>
      <.panel :if={@app} title="Test, package and run" icon="check" id="application-actions">
        <div class="ui-actions">
          <.button
            :for={kind <- ["test", "package"]}
            phx-click="operation"
            phx-value-kind={kind}
            disabled={@job.status == :running}
          >{String.capitalize(kind)}</.button>
        </div>
        <form id="install-application" phx-submit="operation" class="ui-actions">
          <input type="hidden" name="kind" value="install" />
          <select name="device" aria-label={"Install #{@app.name} on"}>
            <option :for={{value, label} <- @targets} value={value}>{label}</option>
          </select>
          <.button type="submit" disabled={@job.status == :running || @targets == []}>Install / review</.button>
        </form>
        <p class="ui-help">
          Simulated installs hold the device reservation and start the package. Physical installs require review and confirmation, and leave the new application stopped and disabled.
        </p>
        <form
          :if={
            @job.status == :awaiting_confirmation && @job.review.kind == :app_install &&
              @job.review.project == @app.path
          }
          id="confirm-install"
          phx-submit="confirm_install"
          class="ui-stack"
        >
          <p>Install {@job.review.app} {@job.review.version} on serial {@job.review.serial}?</p>
          <p class="ui-help">
            SHA-256: {@job.review.sha256}. Application remains stopped and disabled.
          </p>
          <input type="hidden" name="token" value={@job.review.token} />
          <input
            name="address"
            aria-label="Confirm gateway address"
            placeholder={@job.review.address}
            required
          />
          <.button type="submit">Confirm new application install</.button>
        </form>
        <.job
          :if={@job.kind in ["test", "package", "install"] && @job.subject == @app.path}
          job={@job}
        />
      </.panel>
    </main>
    """
  end
end
