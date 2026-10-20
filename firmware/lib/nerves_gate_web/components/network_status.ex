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
      <div class="ui-port" data-internet-uplinks>
        <strong>Internet</strong>
        <p>Ethernet: {connection_label(@projection.connections.internet.ethernet)}</p>
        <p>4G: {connection_label(@projection.connections.internet.cellular)}</p>
        <p :if={@projection.connections.internet.selected}>
          Preferred usable connection: {uplink_label(@projection.connections.internet.selected)}
        </p>
        <.notice :if={@projection.connections.internet.backup == "active"} tone="warning">
          Using 4G backup.
        </.notice>
        <p :if={!@projection.capabilities.mobile} class="ui-help">
          Cellular hardware support is not configured in this firmware.
        </p>
      </div>
      <p :if={@projection.connections.mode == "shared"} class="ui-help">
        Both ports are joined into one shared network.
      </p>
      <p :if={@projection.connections.mode == "ports"} class="ui-help">
        Separate networks. Equipment is not given Internet access.
      </p>
      <p :if={@projection.connections.mode == "unconfigured"} class="ui-help">
        Looking for connections automatically. The ports stay separate.
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

  defp connection_label(:internet), do: "Internet available"
  defp connection_label(:lan), do: "Connected, no verified Internet"
  defp connection_label(:disconnected), do: "Disconnected"
  defp connection_label(:disabled), do: "Not enabled"
  defp connection_label(_), do: "Unknown"

  defp uplink_label("br0"), do: "Shared Ethernet"
  defp uplink_label(name) when name in ["eth0", "eth1"], do: port_label(name)
  defp uplink_label(_), do: "4G modem"

  def equipment_interface(%{connections: %{mode: "shared"}, network: %{observed: observed}}) do
    observed && observed.bridge
  end

  def equipment_interface(projection) do
    Enum.find(projection.connections.ports, &(&1.role == "equipment"))
  end

  def lan_ports(projection) do
    settings =
      (projection.network.pending && projection.network.pending.network) ||
        projection.network.desired

    Enum.map([{"1", "eth0"}, {"2", "eth1"}], fn {id, name} ->
      role =
        if settings && settings["mode"] == "shared" do
          "shared"
        else
          get_in(NervesGate.Config.ports(settings), [name, "role"]) || "unassigned"
        end

      %{
        id: id,
        name: name,
        role: role,
        observed: Enum.find(projection.connections.ports, &(&1.name == name))
      }
    end)
  end

  def equipment_status(nil), do: "Not configured"
  def equipment_status(%{present: false}), do: "Not installed"
  def equipment_status(%{link: true}), do: "Cable connected"
  def equipment_status(_), do: "No cable"

  # Reused in settings and observed port tiles; never expose interface names
  # in everyday controls. Technical names remain available under diagnostics.
  def port_label("eth0") do
    "LAN 1"
  end

  def port_label("eth1") do
    "LAN 2"
  end

  def port_label(_), do: "Ethernet"
  def role_label("internet"), do: "Internet"
  def role_label("equipment"), do: "Equipment"
  def role_label("shared"), do: "Shared network"
  def role_label(_), do: "Unassigned"
end
