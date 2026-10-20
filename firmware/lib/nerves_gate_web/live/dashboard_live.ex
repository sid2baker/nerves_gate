defmodule NervesGateWeb.DashboardLive do
  use Phoenix.LiveView
  alias NervesGate.Config
  alias NervesGateWeb.RemoteStatus
  import NervesGateWeb.CoreComponents
  import NervesGateWeb.NetworkStatus, only: [port_label: 1]

  on_mount({NervesGateWeb.Observations, :status})

  def render(assigns) do
    settings =
      (assigns.projection.network.pending && assigns.projection.network.pending.network) ||
        assigns.projection.network.desired

    assigns =
      assign(assigns,
        settings: settings,
        remote: assigns.projection.remote_access,
        distribution_node: assigns.projection.system.node
      )

    ~H"""
    <.page_header title="Overview" description={@remote.hostname || "Your gateway at a glance."} />
    <p :if={@projection.network.observed && @projection.network.observed.simulated} class="ui-help">
      Preview mode · simulated connections
    </p>
    <.notice :if={@projection.storage.available && @projection.storage.choice == :pending}>
      Application storage is not set up yet.
      <.link navigate="/storage" class="ui-text-link">Set up an SD card or continue without apps →</.link>
    </.notice>
    <section class="ui-connections" aria-label="Gateway connections">
      <.navigation_card
        title="Internet"
        icon="internet"
        href="/network"
        id="connection-internet"
        status={internet_status(@projection)}
        tone={if @projection.connections.internet.health == "online", do: "good", else: "neutral"}
      >
        {internet_detail(@projection, @settings)}
      </.navigation_card>
      <.navigation_card
        title="Remote access"
        icon="shield"
        href="/remote"
        id="connection-tailscale"
        status={RemoteStatus.label(@remote)}
        tone={if @remote.available && @remote.state == "online", do: "good", else: "neutral"}
      >
        {@remote.ipv4 || "Tailscale"}
      </.navigation_card>
      <.navigation_card
        title="Erlang distribution"
        icon="network"
        href="/distribution"
        id="connection-distribution"
        status={if @distribution_node == :nonode@nohost, do: "Not running", else: "Running"}
        tone={if @distribution_node == :nonode@nohost, do: "neutral", else: "good"}
      >
        {if @distribution_node == :nonode@nohost,
          do: "Connect an Erlang or Elixir node",
          else: Atom.to_string(@distribution_node)}
      </.navigation_card>
      <.navigation_card
        title="Application storage"
        icon="equipment"
        href="/storage"
        id="connection-storage"
        status={NervesGateWeb.StorageLive.label(@projection.storage)}
        tone={if @projection.storage.ready, do: "good", else: "neutral"}
      >
        SD card setup · applications and their data
      </.navigation_card>
    </section>
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

    if port, do: port_label(port), else: "Choose an Internet connection"
  end
end
