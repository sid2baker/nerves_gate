defmodule WorkbenchWeb.PluginsLive do
  @moduledoc "Ordinary SDK plugin projects: test, package, and install on a simulated device or physical gateway."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import WorkbenchWeb.Components
  import WorkbenchWeb.Live, only: [command: 2]

  def mount(_, _, socket) do
    if connected?(socket) do
      Scenarios.Runner.subscribe()
      Workbench.Gateways.subscribe()
    end

    {:ok, socket |> assign(plugin_id: nil) |> refresh()}
  end

  def handle_params(params, _, socket),
    do: {:noreply, socket |> assign(:plugin_id, params["id"]) |> refresh()}

  def handle_event(action, %{"plugin" => %{"path" => path}}, socket)
      when action in ["create_plugin", "open_plugin"] do
    result =
      if action == "create_plugin",
        do: Workbench.Plugins.create(path),
        else: Workbench.Plugins.open(path)

    case result do
      {:ok, plugin} ->
        {:noreply, push_navigate(socket, to: "/develop/plugins/#{id(plugin.path)}")}

      error ->
        command(socket, error)
    end
  end

  def handle_event(
        "operation",
        %{"kind" => kind} = params,
        %{assigns: %{plugin: plugin}} = socket
      )
      when not is_nil(plugin) do
    result =
      case kind do
        "test" -> Workbench.Jobs.test_plugin(plugin.path)
        "package" -> Workbench.Jobs.package_plugin(plugin.path)
        "install" -> Workbench.Jobs.install_plugin(plugin.path, params["device"])
      end

    command(socket, result)
  end

  def handle_event("confirm_install", %{"token" => token, "address" => address}, socket),
    do: command(socket, Workbench.Jobs.confirm_plugin(token, address))

  def handle_event("operation", _, socket),
    do: command(socket, {:error, "Open a plugin first"})

  def handle_info({:scenarios, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:gateways, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    plugins = Workbench.Plugins.list()
    bench = Scenarios.Runner.snapshot()

    targets =
      Enum.map(bench.lifecycle.devices, &{to_string(&1.id), "#{&1.id} · simulated"}) ++
        for gateway <- Workbench.Gateways.list(),
            gateway.connected,
            gateway.source == :network,
            do: {to_string(gateway.node), "#{gateway.node} · physical"}

    assign(socket,
      plugins: plugins,
      plugin: Enum.find(plugins, &(id(&1.path) == socket.assigns.plugin_id)),
      targets: targets
    )
  end

  defp id(path), do: Base.url_encode64(path, padding: false)

  def render(assigns) do
    ~H"""
    <main class="ui-main ui-stack bench" id="plugins-page">
      <.back_link :if={@plugin_id} navigate="/develop/plugins">Plugins</.back_link>
      <.page_header
        eyebrow="Develop · Plugins"
        title={if @plugin, do: @plugin.name, else: "Plugins"}
        description={
          if @plugin, do: @plugin.path, else: "Ordinary SDK plugin projects in their own directories."
        }
      />
      <.develop_navigation section={:plugins} />
      <.notice :if={@plugin_id && !@plugin} tone="warning">
        Plugin is not open in this session.
      </.notice>
      <.panel :if={!@plugin_id} title="Create or open a plugin" icon="equipment">
        <form id="create-plugin" phx-submit="create_plugin" class="ui-actions">
          <input
            type="text"
            name="plugin[path]"
            aria-label="New plugin directory"
            placeholder="../my_controller"
            required
          />
          <.button type="submit">Create plugin</.button>
        </form>
        <form id="open-plugin" phx-submit="open_plugin" class="ui-actions">
          <input
            type="text"
            name="plugin[path]"
            aria-label="Existing plugin directory"
            placeholder="/home/me/projects/my_controller"
            required
          />
          <.button type="submit" variant="secondary">Open plugin</.button>
        </form>
      </.panel>
      <.panel
        :if={!@plugin_id}
        title="Firmware plugin sources"
        icon="network"
        id="firmware-plugin-sources"
      >
        <form :for={plugin <- ["tailnet_subrouter", "modbus"]} phx-submit="open_plugin">
          <input
            type="hidden"
            name="plugin[path]"
            value={Path.join([Workbench.root(), "plugins", plugin])}
          />
          <.button type="submit" variant="secondary">Open {plugin} source</.button>
        </form>
        <p class="ui-help">Change plugins/selection.exs and rebuild firmware to bundle plugins.</p>
      </.panel>
      <.panel :if={!@plugin_id} title="Open plugins" icon="equipment" id="plugins">
        <p :if={@plugins == []} class="ui-help">No plugins open.</p>
        <div :for={plugin <- @plugins} class="ui-setting-row">
          <.link navigate={"/develop/plugins/#{id(plugin.path)}"} class="ui-text-link">{plugin.name}</.link>
          <p class="ui-help">{plugin.path}</p>
        </div>
      </.panel>
      <.panel :if={@plugin} title="Test, package and run" icon="check" id="plugin-actions">
        <div class="ui-actions">
          <.button
            :for={kind <- ["test", "package"]}
            phx-click="operation"
            phx-value-kind={kind}
            disabled={@job.status == :running}
          >{String.capitalize(kind)}</.button>
        </div>
        <form id="install-plugin" phx-submit="operation" class="ui-actions">
          <input type="hidden" name="kind" value="install" />
          <select name="device" aria-label={"Install #{@plugin.name} on"}>
            <option :for={{value, label} <- @targets} value={value}>{label}</option>
          </select>
          <.button type="submit" disabled={@job.status == :running || @targets == []}>Install / review</.button>
        </form>
        <p class="ui-help">
          Simulated installs hold the device reservation and start the package. Physical installs require review and confirmation, and leave the new plugin stopped and disabled.
        </p>
        <form
          :if={
            @job.status == :awaiting_confirmation && @job.review.kind == :plugin_install &&
              @job.review.project == @plugin.path
          }
          id="confirm-install"
          phx-submit="confirm_install"
          class="ui-stack"
        >
          <p>Install {@job.review.app} {@job.review.version} on serial {@job.review.serial}?</p>
          <p class="ui-help">
            SHA-256: {@job.review.sha256}. Plugin remains stopped and disabled.
          </p>
          <input type="hidden" name="token" value={@job.review.token} />
          <input
            name="address"
            aria-label="Confirm gateway address"
            placeholder={@job.review.address}
            required
          />
          <.button type="submit">Confirm new plugin install</.button>
        </form>
        <.job
          :if={@job.kind in ["test", "package", "install"] && @job.subject == @plugin.path}
          job={@job}
        />
      </.panel>
    </main>
    """
  end
end
