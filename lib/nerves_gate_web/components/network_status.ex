defmodule NervesGateWeb.NetworkStatus do
  @moduledoc "Presentational network primitives. ConnectionPanel owns their live data."
  use Phoenix.Component
  import NervesGateWeb.CoreComponents

  attr(:projection, :map, required: true)

  def topology(assigns) do
    ~H"""
    <.panel
      title="Your connections"
      description="Current port assignments"
      icon="port"
      aria-label="Connections"
    >
      <div class="ui-port-list">
        <div :for={port <- @projection.connections.ports} class="ui-port" data-port={port.name}>
          <div class="ui-port-header">
            <.icon name="port" /><strong>{port_label(port.name)}</strong><span class="ui-port-role">{role_label(
              port.role
            )}</span>
          </div>
          <.status tone={if port.present && port.link, do: "good", else: "neutral"}>
            {cond do
              not port.present -> "Not installed"
              port.link -> "Cable connected"
              true -> "No cable connected"
            end}
          </.status>
          <code :for={ip <- Map.get(port, :addresses, [])} class="ui-port-address">{ip.address}/{ip.prefix_length}</code>
        </div>
      </div>
      <p :if={@projection.connections.mode == "shared"} class="ui-help">
        Both ports are joined into one shared network.
      </p>
      <p :if={@projection.connections.mode == "ethernet"} class="ui-help">
        Separate networks. Equipment is not given Internet access.
      </p>
      <p :if={@projection.connections.mode == "unconfigured"} class="ui-help">
        Neither port is assigned. The ports are not joined together.
      </p>
      <.notice :if={!@projection.network.observed}>Connection status is unavailable.</.notice>
      <.notice :if={@projection.network.recovering} tone="warning">
        Restoring saved port settings. New changes are paused. Keep USB connected.
      </.notice>
      <.notice :for={problem <- @projection.connections.problems} tone="warning">{problem}</.notice>
      <:footer :if={@projection.network.observed && @projection.network.observed.simulated}>
        <span class="ui-preview-note"><.icon name="info" />Preview mode · simulated connections</span>
      </:footer>
    </.panel>
    """
  end

  attr(:projection, :map, required: true)

  def internet_progress(assigns) do
    assigns = assign(assigns, :internet, assigns.projection.connections.internet)

    ~H"""
    <div class="ui-internet-status">
      <%= cond do %>
        <% !@projection.network.observed -> %>
          <.notice>Connection status is unavailable. Wait for the gateway to reconnect.</.notice>
        <% @projection.connections.mode in [nil, "unconfigured"] -> %>
          <div class="ui-empty-state">
            <span class="ui-icon-box"><.icon name="internet" /></span><h3>
              Choose an Internet connection
            </h3><p>Assign a port to your router in guided setup.</p><a
              href="/setup"
              class="ui-text-link"
            >Set up connections <.icon name="arrow" /></a>
          </div>
        <% true -> %>
          <dl class="ui-health-list">
            <div>
              <dt><.icon name="port" />Cable</dt><dd>
                <.status tone={if @internet.link, do: "good", else: "neutral"}>
                  {if @internet.link, do: "Connected", else: "Not connected"}
                </.status>
              </dd>
            </div>
            <div>
              <dt><.icon name="network" />Address</dt><dd>
                <.status tone={if @internet.addressed, do: "good", else: "neutral"}>
                  {if @internet.addressed, do: "Assigned", else: "Waiting"}
                </.status>
              </dd>
            </div>
            <div>
              <dt><.icon name="internet" />Internet check</dt><dd>
                <.status tone={if @internet.health == "online", do: "good", else: "neutral"}>
                  {if @internet.health == "online", do: "Reachable", else: "Not verified"}
                </.status>
              </dd>
            </div>
          </dl>
          <p class="ui-help">A cable or address alone does not confirm Internet access.</p>
      <% end %>
    </div>
    """
  end

  # Reused in setup, review and observed port tiles; never expose interface names
  # in everyday controls. Technical names remain available under diagnostics.
  def port_label("eth0"), do: "Port 1"
  def port_label("eth1"), do: "Port 2"
  def port_label(_), do: "Ethernet"
  defp role_label("internet"), do: "Internet"
  defp role_label("equipment"), do: "Equipment"
  defp role_label("shared"), do: "Shared network"
  defp role_label(_), do: "Unassigned"
end
