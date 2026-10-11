defmodule NervesGateWeb.DashboardLive do
  use Phoenix.LiveView
  alias NervesGate.Config
  import NervesGateWeb.CoreComponents
  import NervesGateWeb.NetworkStatus, only: [port_label: 1]

  def mount(_, _, socket) do
    socket = NervesGateWeb.Observations.subscribe(socket, &__MODULE__.refresh_observations/1)
    socket = assign(socket, projection: NervesGate.status())

    if socket.assigns.live_action in [:equipment, :internet] do
      {:ok, push_navigate(socket, to: "/settings")}
    else
      {:ok, socket}
    end
  end

  @doc false
  def refresh_observations(socket) do
    assign(socket, projection: NervesGate.status())
  end

  def render(assigns) do
    settings =
      (assigns.projection.network.pending && assigns.projection.network.pending.network) ||
        assigns.projection.network.desired

    assigns =
      assign(assigns,
        settings: settings,
        equipment: equipment_port(settings, assigns.projection),
        remote: assigns.projection.remote_access
      )

    ~H"""
    <.page_header title="Gateway" description={@remote.hostname || "Your connections at a glance."} />
    <div class="ui-disconnected">
      <.notice tone="warning" role="alert">Connection lost. Status may be out of date.</.notice>
    </div>
    <.notice :if={@projection.network.observed && @projection.network.observed.simulated}>
      Preview mode · simulated connections
    </.notice>
    <.notice :if={@projection.network.pending} tone="warning" icon="clock">
      Network changes are not saved yet. <a href="/settings" class="ui-text-link">Keep or restore changes</a>.
    </.notice>
    <.notice :if={!@projection.network.setup_completed}>
      We look for Internet automatically.
      <a href="/setup" class="ui-text-link">Set up your connections</a>
      when you’re ready.
    </.notice>
    <.notice :if={@projection.network.error} tone="warning" role="alert">
      {@projection.network.error.message}
    </.notice>
    <.notice :for={problem <- @projection.connections.problems} tone="warning">{problem}</.notice>
    <section class="ui-connections" aria-label="Gateway connections">
      <.connection
        title="Internet"
        icon="internet"
        href="/settings"
        id="internet"
        tone={if @projection.connections.internet.health == "online", do: "good", else: "neutral"}
        status={internet_status(@projection)}
      >
        {internet_detail(@projection, @settings)}
      </.connection>
      <.connection
        title="Equipment"
        icon="equipment"
        href="/settings"
        id="equipment"
        status={equipment_status(@equipment)}
      >
        {equipment_detail(@equipment)}
      </.connection>
      <.connection
        title="Tailscale"
        icon="shield"
        href="/remote"
        id="tailscale"
        tone={if @remote.state == "online", do: "good", else: "neutral"}
        status={remote_status(@remote)}
      >
        {@remote.ipv4 || "Private access to this gateway"}
      </.connection>
    </section>
    <p class="ui-help">
      Tailscale connects this gateway. Equipment sharing is not enabled by this interface.
    </p>
    <details
      id="connection-details"
      class="ui-details"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
    >
      <summary>Device details</summary>
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

  attr(:title, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:href, :string, required: true)
  attr(:id, :string, required: true)
  attr(:status, :string, required: true)
  attr(:tone, :string, default: "neutral")
  slot(:inner_block, required: true)

  defp connection(assigns) do
    ~H"""
    <a href={@href} class="ui-connection" id={"connection-#{@id}"}>
      <span class="ui-icon-box"><.icon name={@icon} /></span>
      <div class="ui-connection-copy">
        <h2>{@title}</h2><p>{render_slot(@inner_block)}</p>
      </div>
      <.status tone={@tone}>{@status}</.status>
      <.icon name="arrow" />
    </a>
    """
  end

  defp internet_status(%{network: %{observed: nil}}) do
    "Unavailable"
  end

  defp internet_status(%{connections: %{internet: %{health: "online"}}}) do
    "Online"
  end

  defp internet_status(%{connections: %{internet: %{addressed: true}}}) do
    "Internet unverified"
  end

  defp internet_status(%{connections: %{internet: %{link: true}}}) do
    "Waiting for address"
  end

  defp internet_status(_) do
    "Not connected"
  end

  defp internet_detail(%{connections: %{mode: "shared"}}, _) do
    "Shared Ethernet network"
  end

  defp internet_detail(projection, settings) do
    port =
      if settings && settings["mode"] == "unconfigured" do
        projection.connections.suggested_internet_port
      else
        Config.role_port(settings, "internet")
      end

    if port do
      port_label(port)
    else
      "Choose an Internet connection in Network"
    end
  end

  defp equipment_port(%{"mode" => "shared"}, %{network: %{observed: observed}}) do
    observed && observed.bridge
  end

  defp equipment_port(settings, projection) do
    name = Config.role_port(settings, "equipment")
    Enum.find(projection.connections.ports, &(&1.name == name))
  end

  defp equipment_status(nil) do
    "Not configured"
  end

  defp equipment_status(%{link: true}) do
    "Cable connected"
  end

  defp equipment_status(_) do
    "No cable"
  end

  defp equipment_detail(nil) do
    "Add an equipment network when you need it"
  end

  defp equipment_detail(port) do
    addresses = Enum.map_join(port.addresses, ", ", & &1.address)
    Enum.join(Enum.reject([port_label(port.name), addresses], &(&1 == "")), " · ")
  end

  defp remote_status(%{state: "online"}) do
    "Connected"
  end

  defp remote_status(%{auth_state: "needs_approval"}) do
    "Awaiting approval"
  end

  defp remote_status(%{auth_state: "authenticating"}) do
    "Awaiting sign-in"
  end

  defp remote_status(%{available: false}) do
    "Unavailable"
  end

  defp remote_status(_) do
    "Not connected"
  end
end
