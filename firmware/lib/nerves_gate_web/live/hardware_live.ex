defmodule NervesGateWeb.HardwareLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import NervesGateWeb.NetworkStatus, only: [lan_ports: 1, equipment_status: 1, port_label: 1]

  on_mount({NervesGateWeb.Observations, :status})

  def render(assigns) do
    assigns = assign(assigns, ports: lan_ports(assigns.projection))

    ~H"""
    <.page_header title="Hardware" description="Physical interfaces available to applications." />
    <p class="ui-help">
      The gateway manages shared interfaces and access. Applications configure connected equipment,
      protocols and data collection. Opening this page never scans a network or opens a bus.
    </p>
    <section class="ui-stack" aria-labelledby="lan-heading">
      <h2 id="lan-heading">Ethernet</h2>
      <p :if={@projection.connections.mode == "shared"} class="ui-help">
        LAN 1 and LAN 2 share one network. Network observations are not attributed to individual ports.
      </p>
      <div class="ui-connections">
        <.navigation_card
          :for={port <- @ports}
          title={port_label(port.name)}
          icon="port"
          href={"/hardware/lan/#{port.id}"}
          id={"hardware-lan-#{port.id}"}
          status={lan_status(port, @projection.network.observed)}
        >
          {role_label(port.role)}
        </.navigation_card>
      </div>
    </section>
    <section
      :for={
        {kind, title, names} <- [
          {"rs485", "RS485", ["ttyS3", "ttyS4"]},
          {"can", "CAN", ["can0", "can1"]}
        ]
      }
      class="ui-stack"
      aria-label={title}
    >
      <h2>{title}</h2>
      <div class="ui-connections">
        <.navigation_card
          :for={{name, number} <- Enum.with_index(names, 1)}
          title={"#{title} #{number}"}
          icon="port"
          href={"/hardware/#{kind}/#{number}"}
          id={"hardware-#{kind}-#{number}"}
          status={bus_status(@projection.buses, name)}
        >
          {if kind == "rs485",
            do: "Exclusive serial access · passive diagnostics",
            else: "Shared receive access · listen-only diagnostics"}
        </.navigation_card>
      </div>
    </section>
    """
  end

  defp role_label("internet"), do: "Internet uplink · managed under Internet"

  defp role_label("equipment"),
    do: "Existing local configuration · enable application access on its port page"

  defp role_label("application"), do: "Enabled for applications · no default IP configuration"
  defp role_label("shared"), do: "Joined network · LAN 1 + LAN 2"
  defp role_label(_), do: "Application access disabled"

  defp lan_status(_, nil), do: "Unavailable"
  defp lan_status(%{role: "unassigned"}, _), do: "Not configured"
  defp lan_status(%{observed: nil}, _), do: "Not detected"
  defp lan_status(port, _), do: equipment_status(port.observed)

  defp bus_status(%{available: false}, _), do: "Unavailable"

  defp bus_status(buses, name) do
    case Enum.find(buses.ports, &(&1.name == name)) do
      nil -> "Not detected"
      %{present: false} -> "Not detected"
      %{claimed: true} -> "In use by an application"
      %{subscribers: count} when count > 0 -> "In use by applications"
      %{enabled: false} -> "Disabled"
      _ -> "Available"
    end
  end
end
