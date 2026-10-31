defmodule NervesGateWeb.HardwareLive do
  use Phoenix.LiveView, log: false
  import NervesGateWeb.CoreComponents
  import NervesGateWeb.NetworkStatus, only: [lan_ports: 1, port_label: 1]

  on_mount({NervesGateWeb.Observations, :status})

  def render(assigns) do
    ports = Enum.reject(lan_ports(assigns.projection), &(&1.role in ["internet", "shared"]))
    assigns = assign(assigns, ports: ports)

    ~H"""
    <.page_header title="Hardware" description="Physical interfaces available to plugins." />
    <p class="ui-help">
      Assign free interfaces exclusively to plugins. Plugins configure connected equipment,
      protocols and data collection. Internet uplinks belong under Internet, not Hardware. Opening this page never scans a network or opens a bus.
    </p>
    <section class="ui-stack" aria-labelledby="lan-heading">
      <h2 id="lan-heading">Ethernet</h2>
      <p :if={@ports == []} class="ui-help">
        No independent Ethernet ports are available for assignment.
      </p>
      <div class="ui-connections">
        <.navigation_card
          :for={port <- @ports}
          title={port_label(port.name)}
          icon="port"
          href={"/hardware/lan/#{port.id}"}
          id={"hardware-lan-#{port.id}"}
          status={port_status(@projection.hardware, port.name)}
        >
          Exclusive Ethernet assignment · plugin-owned local addressing
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
          status={port_status(@projection.hardware, name)}
        >
          Exclusive plugin assignment · plugin-owned transport
        </.navigation_card>
      </div>
    </section>
    """
  end

  defp port_status(%{available: false}, _), do: "Unavailable"

  defp port_status(hardware, name) do
    case Enum.find(hardware.ports, &(&1.name == name)) do
      nil ->
        "Not detected"

      %{present: false} ->
        "Not detected"

      %{assigned_plugin: plugin, enabled: false} when is_binary(plugin) ->
        "#{plugin} — access disabled"

      %{assigned_plugin: plugin} when is_binary(plugin) ->
        "Assigned to #{plugin}"

      %{enabled: false} ->
        "Unassigned"

      _ ->
        "Available"
    end
  end
end
