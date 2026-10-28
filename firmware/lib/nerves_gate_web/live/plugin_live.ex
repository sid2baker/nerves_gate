defmodule NervesGateWeb.PluginLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  on_mount({NervesGateWeb.Observations, :status})

  def mount(%{"plugin" => plugin}, _, socket) do
    {component, manager_ref} = if connected?(socket), do: mount_plugin(plugin), else: {nil, nil}

    {:ok,
     assign(socket,
       plugin: plugin,
       component: component,
       manager_ref: manager_ref,
       connecting?: not connected?(socket)
     )}
  end

  def handle_info(:plugin_ui_close, _socket), do: exit(:shutdown)

  def handle_info({:DOWN, ref, :process, _, _}, %{assigns: %{manager_ref: ref}}),
    do: exit(:shutdown)

  def handle_info(_, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.page_header title={@plugin} description="Plugin-owned controls" />
    <a href="/plugins" class="ui-text-link">All plugins</a>
    <p :if={@connecting?} class="ui-help">Connecting to plugin…</p>
    <.notice :if={!@connecting? and @component == nil} tone="warning" id="plugin-ui-unavailable">
      Plugin page unavailable. The plugin must be running and supply a UI.
      Reload after it starts. Host-only development previews do not load device plugin code.
    </.notice>
    <.live_component :if={@component} module={@component} id="plugin-ui" />
    """
  end

  defp mount_plugin(plugin) do
    case NervesGate.Plugins.mount_ui(plugin) do
      {:ok, module, manager} ->
        {module, Process.monitor(manager)}

      _ ->
        {nil, nil}
    end
  catch
    :exit, _ -> {nil, nil}
  end
end
