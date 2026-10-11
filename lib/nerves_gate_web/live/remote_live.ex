defmodule NervesGateWeb.RemoteLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  alias NervesGate.Remote.Sharing
  alias NervesGateWeb.RemoteStatus

  on_mount({NervesGateWeb.Observations, :status})

  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         sharing_form: to_form(%{"site" => "", "confirmed" => "false"}, as: :sharing),
         busy: false,
         message: nil
       )}

  def handle_event("change-sharing", %{"sharing" => params}, socket),
    do: {:noreply, assign(socket, :sharing_form, to_form(params, as: :sharing))}

  def handle_event("enable-sharing", %{"sharing" => params}, socket) do
    {:noreply,
     socket
     |> assign(busy: true, message: nil)
     |> start_async(:sharing, fn ->
       NervesGate.equipment_share(params["site"], params["confirmed"] == "true")
     end)}
  end

  def handle_event("disable-sharing", %{"route" => route}, socket) do
    {:noreply,
     socket
     |> assign(busy: true, message: nil)
     |> start_async(:sharing, fn -> NervesGate.equipment_unshare(route) end)}
  end

  def handle_async(:sharing, result, socket) do
    message =
      case result do
        {:ok, :ok} ->
          "Route change verified locally. Tailnet approval, access policy and equipment reachability still need separate checks."

        {:ok, {:error, error}} ->
          error.message

        {:exit, _} ->
          "The reply was lost. Check route state before retrying; the change may still complete."
      end

    {:noreply, assign(socket, busy: false, message: message, projection: NervesGate.status())}
  end

  defp preview(scope, site) do
    with scope when is_map(scope) <- scope, {:ok, site} <- Sharing.site_id(site) do
      Sharing.route(scope, site)
    else
      _ -> nil
    end
  end

  defp endpoint(scope, site, ip) do
    with scope when is_map(scope) <- scope,
         {:ok, site} <- Sharing.site_id(site),
         true <- NervesGate.Equipment.Subnet.host?(scope, ip) do
      Sharing.address(ip, site)
    else
      _ -> nil
    end
  end

  defp destinations(route, entries, scope) do
    with true <- Sharing.matches?(route, scope), {:ok, %{site: site}} <- Sharing.decode(route) do
      Enum.map(entries, fn entry ->
        %{
          id: "via6-#{site}-#{entry.id}",
          local: entry.ip,
          label: entry.label,
          address: Sharing.address(entry.ip, site)
        }
      end)
    else
      _ -> []
    end
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        remote: assigns.projection.remote_access,
        route_preview:
          preview(assigns.projection.sharing.scope, assigns.sharing_form[:site].value),
        endpoint:
          endpoint(
            assigns.projection.sharing.scope,
            assigns.sharing_form[:site].value,
            assigns.sharing_form[:address].value
          )
      )

    ~H"""
    <.page_header
      title="Remote access"
      description="Access to this gateway and its equipment networks."
    />
    <.notice :if={@remote.simulated}>
      Preview mode · Tailscale and route changes are simulated. Your computer’s VPN is never changed.
    </.notice>
    <RemoteStatus.connection remote={@remote}>
      <p>These addresses belong to the gateway, not to equipment connected behind it.</p>
      <.link navigate="/settings/tailscale" class="ui-text-link">
        {if @remote.state == "online", do: "Manage Tailscale connection", else: "Set up Tailscale"}
      </.link>
    </RemoteStatus.connection>
    <.panel title="Equipment networks" icon="equipment" id="equipment-remote-access">
      <p>
        Sharing is opt-in. A dedicated equipment port can be advertised using 4via6 addresses,
        so identical IPv4 subnets at different sites remain distinct. No ordinary IPv4 route is added.
      </p>
      <.notice :if={@message} role="status">{@message}</.notice>
      <.notice :if={@projection.sharing.uncertain != []} tone="warning">
        A route change has an unknown outcome. LAN changes stay blocked until the affected route
        is explicitly withdrawn and verified. A missing advertisement alone does not resolve this.
      </.notice>
      <%= cond do %>
        <% !@remote.available || @remote.advertised_routes == nil -> %>
          <p class="ui-help">
            Advertised routes are unavailable. Equipment access cannot be determined.
          </p>
        <% @remote.advertised_routes == [] -> %>
          <p class="ui-help">Tailscale reports no advertised subnet routes on this gateway.</p>
        <% true -> %>
          <p class="ui-help">
            The daemon’s advertised routes are listed below, including routes configured elsewhere.
          </p>
      <% end %>
      <div :for={route <- @projection.sharing.routes} class="ui-stack ui-route">
        <.setting_row label={
          if route in @projection.sharing.uncertain, do: "Uncertain route", else: "Advertised route"
        }>
          <code>{route}</code>
        </.setting_row>
        <.button
          :if={match?({:ok, _}, Sharing.decode(route))}
          phx-click="disable-sharing"
          phx-value-route={route}
          disabled={@busy || !@projection.actions["equipment.unshare"].enabled}
          variant="quiet"
        >
          Withdraw this route
        </.button>
        <p :if={!match?({:ok, _}, Sharing.decode(route))} class="ui-help">
          External route: preserved, not managed here. Review it in your Tailscale configuration.
        </p>
        <div
          :for={
            device <- destinations(route, @projection.equipment.entries, @projection.sharing.scope)
          }
          class="ui-field"
        >
          <label for={device.id}>{if device.label == "",
            do: device.local,
            else: "#{device.label} · #{device.local}"}</label>
          <input
            id={device.id}
            value={device.address}
            readonly
            phx-hook="CopyAddress"
            aria-describedby="via6-help"
          />
          <span class="ui-help">Select the address, then copy it.</span>
        </div>
      </div>
      <.notice tone="warning">
        Advertisement does not prove approval or reachability. Approve the route and restrict access
        in your tailnet policy, then test the intended equipment service from an authorized client.
      </.notice>
      <.form
        for={@sharing_form}
        id="equipment-sharing-form"
        class="ui-stack"
        phx-change="change-sharing"
        phx-submit="enable-sharing"
      >
        <.field
          field={@sharing_form[:site]}
          label="Tailnet-unique site ID"
          inputmode="numeric"
          help="0–65535. Ask your tailnet administrator to assign an unused ID. This gateway cannot verify uniqueness."
        />
        <label class="ui-check">
          <input type="hidden" name="sharing[confirmed]" value="false" />
          <input
            type="checkbox"
            name="sharing[confirmed]"
            value="true"
            checked={@sharing_form[:confirmed].value == "true"}
          />
          I am authorized to share this equipment and have confirmed this site ID is unique in my tailnet.
        </label>
        <p :if={@route_preview}>Route to advertise: <code>{@route_preview}</code></p>
        <.field
          field={@sharing_form[:address]}
          label="Equipment IPv4 address (optional address calculator)"
          help="Enter a known equipment address, even if discovery did not find it. Use the site ID of its advertised route."
        />
        <div :if={@endpoint} class="ui-field">
          <label for="calculated-via6">Equipment IPv6 address · select, then copy</label>
          <input id="calculated-via6" value={@endpoint} readonly phx-hook="CopyAddress" />
        </div>
        <.button
          type="submit"
          id="enable-equipment-sharing"
          disabled={@busy || !@projection.actions["equipment.share"].enabled}
        >
          {if @busy || @remote.operation in ["sharing_enable", "sharing_disable", "sharing_sync"],
            do: "Updating sharing…",
            else: "Share equipment subnet"}
        </.button>
        <p :if={@projection.actions["equipment.share"].reason} class="ui-help">
          {@projection.actions["equipment.share"].reason.message}
        </p>
      </.form>
      <p id="via6-help" class="ui-help">
        Clients and applications must support IPv6. Use brackets around IPv6 literals in URLs,
        for example http://[address]:port. IPv4-only applications and broadcast discovery are not
        supported by 4via6. There is no ambiguous IPv4 fallback. Local discovery is optional; silent
        equipment can still be addressed using the same site ID and its known IPv4 address.
      </p>
      <p class="ui-help">
        This page changes advertisements only; it does not install a firewall or pin traffic to a port.
        Tailscale uses the gateway’s routing table. Withdrawing a route or disconnecting Tailscale
        is not proof that existing sessions have ended. Other preferences and enrollment are preserved.
      </p>
      <.link navigate="/equipment" class="ui-text-link">View local equipment connection</.link>
    </.panel>
    <p class="ui-help">
      <a
        href="https://login.tailscale.com/admin/machines"
        target="_blank"
        rel="noopener noreferrer"
        class="ui-text-link"
      >Open Tailscale admin console</a>.
      Restrict access to port 4000 with your Tailscale policy. This web interface has no sign-in protection.
    </p>
    """
  end
end
