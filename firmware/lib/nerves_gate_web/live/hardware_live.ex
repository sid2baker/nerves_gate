defmodule NervesGateWeb.HardwareLive do
  use Phoenix.LiveView, log: false
  import NervesGateWeb.CoreComponents

  on_mount({NervesGateWeb.Observations, :status})

  # Section order and headings for each kind a board may declare.
  @sections [
    ethernet: "Ethernet",
    rs485: "RS485",
    can: "CAN",
    iotrouter_expansion: "Expansion bus"
  ]

  def render(assigns) do
    # Internet uplinks belong to Network, not to plugins.
    network = assigns.projection.network.desired
    internet = NervesGate.Config.role_port(network, "internet")

    ports =
      Enum.reject(assigns.projection.hardware.ports, fn port ->
        not port.assignable or (port.kind == :ethernet and port.id == internet)
      end)

    sections =
      for {kind, title} <- @sections,
          kind_ports = Enum.filter(ports, &(&1.kind == kind)),
          kind_ports != [] or kind == :ethernet,
          do: {kind, title, kind_ports}

    assigns = assign(assigns, sections: sections)

    ~H"""
    <.page_header title="Hardware" description="Physical interfaces available to plugins." />
    <p class="ui-help">
      Assign free interfaces exclusively to plugins. Plugins configure connected equipment,
      protocols and data collection. Internet uplinks belong under Internet, not Hardware. Opening this page never scans a network or opens a bus.
    </p>
    <p :if={!@projection.hardware.available} role="alert">Hardware inventory unavailable.</p>
    <section
      :for={{kind, title, ports} <- @sections}
      class="ui-stack"
      aria-label={title}
      id={"hardware-#{kind}"}
    >
      <h2>{title}</h2>
      <p :if={ports == []} class="ui-help">
        No independent Ethernet ports are available for assignment.
      </p>
      <div class="ui-connections">
        <.navigation_card
          :for={port <- ports}
          title={port.label}
          icon="port"
          href={"/hardware/#{port.id}"}
          id={"hardware-#{port.id}"}
          status={port_status(port)}
        >
          {port.id} · exclusive plugin assignment · plugin-owned protocol
        </.navigation_card>
      </div>
    </section>
    """
  end

  defp port_status(%{present: present}) when present != true, do: "Not detected"

  defp port_status(%{assigned_plugin: plugin, enabled: false}) when is_binary(plugin),
    do: "#{plugin} — access disabled"

  defp port_status(%{assigned_plugin: plugin}) when is_binary(plugin), do: "Assigned to #{plugin}"
  defp port_status(%{enabled: false}), do: "Unassigned"
  defp port_status(_), do: "Available"
end
