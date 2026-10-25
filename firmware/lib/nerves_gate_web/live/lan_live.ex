defmodule NervesGateWeb.LanLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import NervesGateWeb.NetworkStatus, only: [lan_ports: 1, equipment_status: 1, port_label: 1]

  on_mount({NervesGateWeb.Observations, :status})
  on_mount({NervesGateWeb.Access, :network})

  def handle_params(%{"id" => id}, _, socket) do
    case Enum.find(lan_ports(socket.assigns.projection), &(&1.id == id)) do
      nil -> {:noreply, push_navigate(socket, to: "/hardware")}
      port -> {:noreply, assign(socket, :name, port.name)}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  def render(assigns) do
    port = Enum.find(lan_ports(assigns.projection), &(&1.name == assigns.name))
    local = Map.get(assigns.projection.network, :local)

    assigns =
      assign(assigns, port: port, local: if(local && local.interface == assigns.name, do: local))

    ~H"""
    <.back_link navigate="/hardware">Hardware</.back_link>
    <.page_header
      title={port_label(@name)}
      description="Physical Ethernet interface available to applications."
    />
    <.panel title="Interface" icon="port" id="ethernet-interface">
      <.setting_row label="Link">
        {if @projection.network.observed, do: equipment_status(@port.observed), else: "Unavailable"}
      </.setting_row>
      <.setting_row label="Use">
        {case @port.role do
          "internet" -> "Internet uplink"
          "shared" -> "Joined network · administrator-owned"
          "application" -> "Enabled for applications"
          "equipment" -> "Existing local configuration"
          _ -> "Application access disabled"
        end}
      </.setting_row>
      <.setting_row :if={@port.observed} label="Observed addresses">
        <span :if={@port.observed.addresses == []}>None</span>
        <code :for={address <- @port.observed.addresses}>{address.address}/{address.prefix_length}</code>
      </.setting_row>
      <.notice :if={@local} id="local-claim-status">
        Application resource: {@local.phase}. {if @local.error, do: @local.error.message} Release the owning application's claim before changing this interface.
      </.notice>
      <.link :if={@port.role == "internet"} navigate="/network" class="ui-text-link">Manage Internet</.link>
      <p class="ui-help">
        The gateway controls availability and arbitrates access. Applications request local addressing
        and own equipment protocols. No scan, DHCP client, route advertisement or bridge is started by opening this page.
      </p>
    </.panel>
    <.live_component
      module={NervesGateWeb.NetworkEditor}
      id={"application-port-#{@name}"}
      editor={{:application, @name}}
      projection={@projection}
      access={@access}
    />
    """
  end
end
