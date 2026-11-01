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
        Preferred usable uplink: {uplink_label(
          @projection.connections.internet.selected,
          @projection.connections.ports
        )}
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
          {port_label(interface.name, @projection.connections.ports)}
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
        <.setting_row label="Traffic">{traffic_label(interface)}</.setting_row>
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

  @doc "Kernel byte counters since the interface came up."
  def traffic_label(%{traffic: %{received: received, sent: sent}}),
    do: "#{bytes(received)} received, #{bytes(sent)} sent since start"

  def traffic_label(_), do: "Not reported"

  defp bytes(n) when n >= 1_000_000_000, do: "#{Float.round(n / 1_000_000_000, 2)} GB"
  defp bytes(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)} MB"
  defp bytes(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)} kB"
  defp bytes(n), do: "#{n} B"

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

  defp uplink_label(nil, _), do: "Not identified"

  defp uplink_label(name, ports) do
    if Enum.any?(ports, &(&1.name == name)), do: port_label(name, ports), else: "4G modem"
  end

  def cable_status(nil), do: "Not configured"
  def cable_status(%{present: false}), do: "Not installed"
  def cable_status(%{link: true}), do: "Cable connected"
  def cable_status(_), do: "No cable"

  @doc "The board label of an observed Ethernet port; interface names stay under diagnostics."
  def port_label(name, ports),
    do: Enum.find_value(ports, "Ethernet", &(&1.name == name && Map.get(&1, :label)))

  def role_label("internet"), do: "Internet"
  def role_label(_), do: "Unassigned"
end
