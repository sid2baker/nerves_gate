defmodule NervesGateWeb.DashboardLive do
  use Phoenix.LiveView
  alias NervesGate.Config
  alias NervesGateWeb.RemoteStatus
  import NervesGateWeb.CoreComponents

  import NervesGateWeb.NetworkStatus,
    only: [port_label: 1, equipment_interface: 1, equipment_status: 1]

  on_mount({NervesGateWeb.Observations, :status})

  def render(assigns) do
    settings =
      (assigns.projection.network.pending && assigns.projection.network.pending.network) ||
        assigns.projection.network.desired

    assigns =
      assign(assigns,
        settings: settings,
        equipment: equipment_interface(assigns.projection),
        remote: assigns.projection.remote_access
      )

    ~H"""
    <.page_header title="Overview" description={@remote.hostname || "Your gateway at a glance."} />
    <.notice :if={@projection.network.observed && @projection.network.observed.simulated}>
      Preview mode · simulated connections
    </.notice>
    <p :if={!@projection.network.setup_completed} class="ui-help">
      Looking for Internet automatically. When you’re ready, <.link
        navigate="/settings/network"
        class="ui-text-link"
      >configure your connections in Settings</.link>.
    </p>
    <.notice :if={@projection.network.error} tone="warning" role="alert">
      {@projection.network.error.message}
    </.notice>
    <.notice :for={problem <- @projection.connections.problems} tone="warning">{problem}</.notice>
    <section class="ui-connections" aria-label="Gateway connections">
      <.navigation_card
        title="Equipment"
        icon="equipment"
        href="/equipment"
        id="connection-equipment"
        status={
          if @projection.network.observed, do: equipment_status(@equipment), else: "Unavailable"
        }
      >
        {equipment_detail(@equipment)}
      </.navigation_card>
      <.navigation_card
        title="Remote access"
        icon="shield"
        href="/remote"
        id="connection-tailscale"
        status={RemoteStatus.label(@remote)}
        tone={if @remote.available && @remote.state == "online", do: "good", else: "neutral"}
      >
        {@remote.ipv4 || "Private access to this gateway through Tailscale"}
      </.navigation_card>
      <.navigation_card
        title="Internet"
        icon="internet"
        href="/settings/network"
        id="connection-internet"
        status={internet_status(@projection)}
        tone={if @projection.connections.internet.health == "online", do: "good", else: "neutral"}
      >
        {internet_detail(@projection, @settings)}
      </.navigation_card>
    </section>
    <details
      id="connection-details"
      class="ui-details"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
    >
      <summary>Gateway details</summary>
      <div class="ui-stack">
        <.live_component
          module={NervesGateWeb.ConnectionPanel}
          id="gateway-connections"
          projection={@projection}
        />
        <p class="ui-help">
          Firmware {@projection.system.firmware} · {@projection.system.target}. USB remains separate for setup and recovery.
        </p>
      </div>
    </details>
    """
  end

  defp internet_status(%{network: %{observed: nil}}), do: "Unavailable"
  defp internet_status(%{connections: %{internet: %{health: "online"}}}), do: "Online"
  defp internet_status(%{connections: %{internet: %{addressed: true}}}), do: "Internet unverified"
  defp internet_status(%{connections: %{internet: %{link: true}}}), do: "Waiting for address"
  defp internet_status(_), do: "Not connected"

  defp internet_detail(%{connections: %{internet: %{backup: "active"}}}, _),
    do: "4G backup in use"

  defp internet_detail(%{connections: %{internet: %{mode: "cellular"}}}, _), do: "4G modem"
  defp internet_detail(%{connections: %{mode: "shared"}}, _), do: "Shared Ethernet network"

  defp internet_detail(projection, settings) do
    port =
      if settings && settings["mode"] == "unconfigured",
        do: projection.connections.suggested_internet_port,
        else: Config.role_port(settings, "internet")

    if port, do: port_label(port), else: "Choose an Internet connection in Settings"
  end

  defp equipment_detail(nil), do: "Configure an equipment connection in Settings"

  defp equipment_detail(port) do
    addresses = Enum.map_join(port.addresses, ", ", & &1.address)
    Enum.join(Enum.reject([port_label(port.name), addresses], &(&1 == "")), " · ")
  end
end
