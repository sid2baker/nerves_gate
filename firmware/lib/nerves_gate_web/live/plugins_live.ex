defmodule NervesGateWeb.PluginsLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  on_mount({NervesGateWeb.Observations, :status})

  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_plugins, 2_000)
    {:ok, assign(socket, plugins: plugins(), busy: false, unknown?: false, outcome: nil)}
  end

  def handle_info(:refresh_plugins, socket) do
    Process.send_after(self(), :refresh_plugins, 2_000)
    {:noreply, assign(socket, :plugins, plugins())}
  end

  def handle_event(_, _, %{assigns: %{busy: true}} = socket), do: {:noreply, socket}

  def handle_event("refresh-state", _, socket) do
    case plugins() do
      :unavailable ->
        {:noreply, assign(socket, :outcome, "Plugin state unavailable.")}

      plugins ->
        {:noreply,
         assign(socket,
           plugins: plugins,
           unknown?: false,
           outcome: "State refreshed. Inspect it before another command."
         )}
    end
  end

  def handle_event(
        "select-version",
        %{"app" => app, "version" => version},
        %{assigns: %{unknown?: false}} = socket
      ) do
    {:noreply,
     socket
     |> assign(busy: true, outcome: nil)
     |> start_async(:plugin_command, fn -> NervesGate.Plugins.select(app, version) end)}
  end

  def handle_event(action, %{"app" => app}, %{assigns: %{unknown?: false}} = socket)
      when action in ["start-plugin", "stop-plugin"] do
    operation = if action == "start-plugin", do: :start, else: :stop

    {:noreply,
     socket
     |> assign(busy: true, outcome: nil)
     |> start_async(:plugin_command, fn -> apply(NervesGate.Plugins, operation, [app]) end)}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  def handle_async(:plugin_command, {:ok, result}, socket) do
    {message, uncertain} =
      case result do
        :ok -> {"Plugin command completed.", false}
        {:error, reason} -> {"Plugin command failed: #{inspect(reason)}", uncertain?(reason)}
      end

    {:noreply,
     assign(socket, busy: false, plugins: plugins(), outcome: message, unknown?: uncertain)}
  end

  def handle_async(:plugin_command, {:exit, _}, socket) do
    {:noreply,
     assign(socket,
       busy: false,
       plugins: plugins(),
       unknown?: true,
       outcome:
         "Command outcome unknown. Refresh and inspect state; nothing is retried automatically."
     )}
  end

  def render(assigns) do
    ~H"""
    <.page_header
      title="Plugins"
      description="Trusted extensions selected in this firmware. Starting a plugin does not configure equipment."
    />
    <.notice :if={@plugins == :unavailable} tone="warning">Plugin management unavailable.</.notice>
    <.notice :if={@outcome} tone="neutral" id="plugin-operation-result">{@outcome}</.notice>
    <p :if={@unknown?} role="alert">
      A command outcome is unresolved. Refresh and inspect state before continuing.
    </p>
    <button class="ui-button ui-button--secondary" phx-click="refresh-state" disabled={@busy}>Refresh plugin state</button>
    <p :if={@plugins == []}>No plugins selected in this firmware.</p>
    <section :if={is_list(@plugins)} class="ui-stack" id="plugins">
      <article :for={plugin <- @plugins} class="ui-panel">
        <div class="ui-panel-body">
          <h2>{plugin.app}</h2>
          <p>
            {plugin.active_version} · {if plugin.running?, do: "Running", else: "Stopped"} · {if plugin.bundled?,
              do: "Firmware",
              else: "Development"}
          </p>
          <p :if={plugin.error} role="alert">{inspect(plugin.error)}</p>
          <div class="ui-actions">
            <button
              :if={
                plugin.available_version != nil and plugin.active_version != plugin.available_version
              }
              class="ui-button ui-button--secondary"
              phx-click="select-version"
              phx-value-app={plugin.app}
              phx-value-version={plugin.available_version}
              disabled={@busy or @unknown?}
            >Select firmware version {plugin.available_version} · leave stopped</button>
            <a
              :if={plugin.ui? and plugin.running?}
              href={"/plugins/#{plugin.app}"}
              class="ui-button ui-button--primary"
            >Open plugin</a>
            <button
              :if={!plugin.running?}
              class="ui-button ui-button--secondary"
              phx-click="start-plugin"
              phx-value-app={plugin.app}
              disabled={@busy or @unknown?}
            >Start</button>
            <button
              :if={plugin.running? or plugin.operation != nil or plugin.error != nil}
              class="ui-button ui-button--secondary"
              phx-click="stop-plugin"
              phx-value-app={plugin.app}
              disabled={@busy or @unknown?}
            >Stop</button>
          </div>
        </div>
      </article>
    </section>
    <p class="ui-help">
      Add, update or remove bundled plugin code by rebuilding firmware. No libraries are downloaded on the device.
    </p>
    """
  end

  defp plugins do
    case NervesGate.Plugins.list() do
      {:ok, plugins} -> plugins
      _ -> :unavailable
    end
  catch
    :exit, _ -> :unavailable
  end

  defp uncertain?(reason)
       when reason in [:operation_timeout, :lifecycle_failed, :metadata_commit_unknown], do: true

  defp uncertain?({:metadata_write, :metadata_commit_unknown}), do: true
  defp uncertain?(_), do: false
end
