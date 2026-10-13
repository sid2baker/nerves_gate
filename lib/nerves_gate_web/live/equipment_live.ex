defmodule NervesGateWeb.EquipmentLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import NervesGateWeb.NetworkStatus, only: [lan_ports: 1, equipment_status: 1, port_label: 1]

  on_mount({NervesGateWeb.Observations, :status})

  def render(assigns) do
    assigns =
      assign(assigns, ports: Enum.reject(lan_ports(assigns.projection), &(&1.role == "internet")))

    ~H"""
    <.page_header title="Equipment" description="Choose a physical connection." />
    <section class="ui-stack" aria-labelledby="lan-heading">
      <h2 id="lan-heading">LAN</h2>
      <p :if={@projection.connections.mode == "shared"} class="ui-help">
        LAN 1 and LAN 2 share one network. Devices cannot be attributed to an individual port.
      </p>
      <div class="ui-connections">
        <.navigation_card
          :for={port <- @ports}
          title={port_label(port.name)}
          icon="port"
          href={"/equipment/lan/#{port.id}"}
          id={"equipment-lan-#{port.id}"}
          status={lan_status(port, @projection.network.observed)}
        >
          {if port.role == "shared", do: "Shared network", else: "Equipment connection"}
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
          href={"/equipment/#{kind}/#{number}"}
          id={"equipment-#{kind}-#{number}"}
          status={bus_status(@projection.buses, name)}
        >
          {if kind == "rs485", do: "Serial diagnostics", else: "Listen-only diagnostics"}
        </.navigation_card>
      </div>
    </section>
    """
  end

  defp lan_status(_, nil), do: "Unavailable"
  defp lan_status(%{role: "unassigned"}, _), do: "Not configured"
  defp lan_status(%{observed: nil}, _), do: "Not detected"
  defp lan_status(port, _), do: equipment_status(port.observed)

  defp bus_status(%{available: false}, _), do: "Unavailable"

  defp bus_status(buses, name) do
    case Enum.find(buses.ports, &(&1.name == name)) do
      nil -> "Not detected"
      %{present: false} -> "Not detected"
      %{enabled: false} -> "Disabled"
      _ -> "Enabled"
    end
  end
end
