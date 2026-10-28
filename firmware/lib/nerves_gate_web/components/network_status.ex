defmodule NervesGateWeb.NetworkStatus do
  @moduledoc "Presentational network primitives rendered from device-owned observations."
  use Phoenix.Component
  import NervesGateWeb.CoreComponents

  attr(:projection, :map, required: true)

  def internet_summary(assigns) do
    ~H"""
    <.panel title="Internet" id="internet-uplink-summary" icon="internet">
      <p><strong>{source_label(@projection.connections.internet.mode)}</strong></p>
      <.setting_row :if={@projection.connections.internet.mode != "cellular"} label="LAN">
        {connection_label(@projection.connections.internet.ethernet)}
      </.setting_row>
      <.setting_row
        :if={@projection.connections.internet.mode in ["cellular", "backup"]}
        label={if @projection.connections.internet.mode == "backup", do: "4G backup", else: "4G"}
      >
        {cellular_connection(@projection)}
      </.setting_row>
      <p
        :if={@projection.connections.internet.mode == "backup"}
        id="internet-backup-status"
        class="ui-help"
      >
        Preferred usable uplink: {uplink_label(@projection.connections.internet.selected)}
      </p>
      <.notice :if={!@projection.network.observed}>Connection status is unavailable.</.notice>
      <.notice :if={@projection.network.recovering} tone="warning">
        Restoring saved port settings. New changes are paused. Keep USB connected.
      </.notice>
      <.notice :for={problem <- @projection.connections.problems} tone="warning">{problem}</.notice>
    </.panel>
    """
  end

  attr(:projection, :map, required: true)

  def lan_internet(assigns) do
    interfaces =
      case assigns.projection.connections.mode do
        "shared" ->
          List.wrap(
            assigns.projection.network.observed && assigns.projection.network.observed.bridge
          )

        "unconfigured" ->
          assigns.projection.connections.ports

        _ ->
          Enum.filter(assigns.projection.connections.ports, &(&1.role == "internet"))
      end

    assigns = assign(assigns, :interfaces, interfaces)

    ~H"""
    <.panel title="LAN Internet" id="internet-lan-status" icon="port">
      <.notice :if={!@projection.network.observed}>LAN status is unavailable.</.notice>
      <p :if={@projection.network.observed != nil and @interfaces == []}>
        No LAN Internet port is currently assigned. Apply a LAN source to configure one.
      </p>
      <section :for={interface <- @interfaces} data-internet-port={interface.name}>
        <.setting_row label="Port">
          {if interface.name == "br0", do: "Joined LAN 1 + LAN 2", else: port_label(interface.name)}
        </.setting_row>
        <.setting_row label="Cable">
          {cable_status(interface)}
        </.setting_row>
        <.setting_row label="Address assignment">{method_label(interface.method)}</.setting_row>
        <.setting_row label="IP addresses">
          <span :if={interface.addresses == []}>Not assigned</span>
          <code :for={ip <- interface.addresses}>{ip.address}/{ip.prefix_length}</code>
        </.setting_row>
        <.setting_row label="Internet">{connection_label(interface.connection)}</.setting_row>
        <div class="ui-stack">
          <.setting_row label="Gateway">{interface.gateway || "Not reported"}</.setting_row>
          <.setting_row label="DNS servers">
            {if interface.nameservers == [],
              do: "Not reported",
              else: Enum.join(interface.nameservers, ", ")}
          </.setting_row>
        </div>
      </section>
    </.panel>
    """
  end

  defp cellular_connection(projection) do
    case projection.cellular.sim do
      :pin_required -> "PIN required"
      :absent -> "No SIM detected"
      sim when sim in [:puk_required, :pin2_required, :puk2_required] -> "SIM recovery required"
      _ -> connection_label(projection.connections.internet.cellular)
    end
  end

  def connection_label(:internet), do: "Internet available"
  def connection_label(:lan), do: "Connected, no verified Internet"
  def connection_label(:disconnected), do: "Disconnected"
  def connection_label(:disabled), do: "Not enabled"
  def connection_label(_), do: "Unknown"

  defp source_label("ethernet"), do: "LAN"
  defp source_label("cellular"), do: "4G"
  defp source_label("backup"), do: "LAN with 4G backup"
  defp source_label(_), do: "Unknown"

  defp method_label("dhcp"), do: "Automatic (DHCP)"
  defp method_label("static"), do: "Static"
  defp method_label(_), do: "Unknown"

  defp uplink_label(nil), do: "Not identified"
  defp uplink_label("br0"), do: "Joined LAN"
  defp uplink_label(name) when name in ["eth0", "eth1"], do: port_label(name)
  defp uplink_label(_), do: "4G modem"

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

  def cable_status(nil), do: "Not configured"
  def cable_status(%{present: false}), do: "Not installed"
  def cable_status(%{link: true}), do: "Cable connected"
  def cable_status(_), do: "No cable"

  # Technical interface names remain available under diagnostics.
  def port_label("eth0"), do: "LAN 1"
  def port_label("eth1"), do: "LAN 2"
  def port_label(_), do: "Ethernet"
  def role_label("internet"), do: "Internet"
  def role_label("shared"), do: "Shared network"
  def role_label(_), do: "Unassigned"
end
