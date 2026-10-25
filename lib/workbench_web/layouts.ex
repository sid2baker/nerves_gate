defmodule WorkbenchWeb.Layouts do
  @moduledoc "Workbench navigation and operation status, separate from the device gateway layout."
  use Phoenix.Component
  import NervesGateWeb.CoreComponents
  import WorkbenchWeb.Components

  def app(assigns) do
    ~H"""
    <a href="#main-content" class="ui-skip-link">Skip to content</a>
    <div class="dev-shell">
      <aside class="dev-sidebar">
        <.link navigate="/" class="ui-brand"><.icon name="network" />Nerves Gate</.link>
        <p class="ui-help dev-brand-caption">Developer workbench</p>
        <nav aria-label="Workbench navigation" class="dev-navigation">
          <.link
            :for={{section, path, label, icon} <- navigation()}
            navigate={path}
            aria-current={if current_section(@live_action) == section, do: "page"}
          ><.icon name={icon} />{label}</.link>
        </nav>
      </aside>
      <div class="dev-content">
        <header class="dev-topbar">
          <.link
            navigate={operation_path(@operation)}
            class="dev-operation-link"
            id="global-operation"
            aria-live="polite"
          >
            <.status tone={result_tone(@operation.status)}>
              {operation_label(@operation.kind)} · {@operation.status}
            </.status>
          </.link>
          <.theme_toggle />
        </header>
        <div id="main-content" tabindex="-1">
          <div class="dev-notices ui-stack">
            <div class="ui-disconnected">
              <.notice tone="warning" role="alert">
                Workbench disconnected. Observations may be stale. Operations continue;
                device actions will not be retried automatically.
              </.notice>
            </div>
            <.notice :if={@error} tone="warning" role="alert" id="workbench-error">{@error}</.notice>
          </div>
          {@inner_content}
        </div>
      </div>
    </div>
    """
  end

  defp current_section(action) when action in [:apps, :firmware, :scenarios, :manual, :simulator],
    do: :develop

  defp current_section(action), do: action

  defp navigation do
    [
      {:overview, "/", "Home", "overview"},
      {:develop, "/develop", "Develop", "equipment"},
      {:devices, "/devices", "Devices", "network"},
      {:factory, "/provision", "Provision", "usb"}
    ]
  end
end
