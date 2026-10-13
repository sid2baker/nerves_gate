defmodule NervesGateWeb.RemoteLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  alias NervesGateWeb.{DistributionPanel, RemoteStatus}

  on_mount({NervesGateWeb.Observations, :status})

  def mount(_, _, socket), do: {:ok, assign(socket, busy: false, message: nil)}

  def handle_event("enable-sharing", _, socket),
    do: {:noreply, change_sharing(socket, &NervesGate.equipment_share/0)}

  def handle_event("disable-sharing", _, socket),
    do: {:noreply, change_sharing(socket, &NervesGate.equipment_unshare/0)}

  defp change_sharing(socket, command) do
    socket |> assign(busy: true, message: nil) |> start_async(:sharing, command)
  end

  def handle_async(:sharing, result, socket) do
    message =
      case result do
        {:ok, :ok} -> nil
        {:ok, {:error, error}} -> error.message
        {:exit, _} -> "The reply was lost. Check sharing state before retrying."
      end

    {:noreply, assign(socket, busy: false, message: message, projection: NervesGate.status())}
  end

  def render(assigns) do
    sharing = assigns.projection.sharing
    action = if sharing.enabled == false, do: "equipment.share", else: "equipment.unshare"

    assigns =
      assign(assigns,
        remote: assigns.projection.remote_access,
        sharing: sharing,
        action: assigns.projection.actions[action],
        distribution_node: Node.self(),
        distribution_cookie: Node.get_cookie()
      )

    ~H"""
    <.page_header
      title="Remote access"
      description="Reach this gateway and its equipment through Tailscale."
    />
    <.notice :if={@remote.simulated}>
      Preview mode · Tailscale and sharing are simulated. Your computer’s VPN is never changed.
    </.notice>
    <RemoteStatus.connection remote={@remote}>
      <.link navigate="/settings/tailscale" class="ui-text-link">
        {if @remote.state == "online", do: "Manage Tailscale connection", else: "Set up Tailscale"}
      </.link>
    </RemoteStatus.connection>
    <.panel title="Equipment network" icon="equipment" id="equipment-remote-access">
      <.setting_row label="Equipment subnet">
        <code :if={@sharing.subnet}>{@sharing.subnet}</code>
        <.link :if={!@sharing.subnet} navigate="/settings/network" class="ui-text-link">
          Configure a dedicated equipment port
        </.link>
      </.setting_row>
      <.setting_row label="Share equipment network">
        <strong id="equipment-sharing-state">
          {case @sharing.enabled do
            true -> "On"
            false -> "Off"
            nil -> "Unknown"
          end}
        </strong>
      </.setting_row>
      <.notice :if={@message} tone="warning" role="status">{@message}</.notice>
      <.notice :if={@sharing.enabled == nil} tone="warning">
        Sharing state is unknown. Turn it off to verify withdrawal before changing LAN settings.
      </.notice>
      <.button
        id="equipment-sharing-toggle"
        phx-click={if @sharing.enabled == false, do: "enable-sharing", else: "disable-sharing"}
        disabled={@busy || !@action.enabled}
      >
        {cond do
          @busy -> "Updating sharing…"
          @sharing.enabled == false -> "Turn sharing on"
          true -> "Turn sharing off"
        end}
      </.button>
      <p :if={@action.reason} class="ui-help">{@action.reason.message}</p>
      <p class="ui-help">
        Use equipment’s normal IPv4 addresses. Approve this subnet in Tailscale and allow access
        in your tailnet policy, then test the equipment connection. On means advertised, not verified reachable.
      </p>
      <p class="ui-help">
        Overlapping networks are not supported. Your computer’s LAN and other VPNs must not use
        the same or an overlapping subnet. Broadcast discovery does not cross this connection.
      </p>
      <.notice :if={@sharing.other_routes != []} tone="warning">
        Other subnet routes may still provide equipment access. This control leaves them unchanged;
        remove those advertisements in Tailscale before changing LAN settings.
      </.notice>
      <.link navigate="/equipment" class="ui-text-link">View local equipment</.link>
    </.panel>
    <DistributionPanel.connection
      node={@distribution_node}
      cookie={@distribution_cookie}
      elixir={System.version()}
      otp={System.otp_release()}
    />
    <p class="ui-help">
      <a
        href="https://login.tailscale.com/admin/machines"
        target="_blank"
        rel="noopener noreferrer"
      >Open Tailscale admin console</a>.
      Restrict access to port 4000 with your Tailscale policy. This web interface has no sign-in protection.
    </p>
    """
  end
end
