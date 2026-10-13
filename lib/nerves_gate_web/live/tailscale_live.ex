defmodule NervesGateWeb.TailscaleLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  alias NervesGateWeb.RemoteStatus

  def mount(_, _, socket) do
    socket = NervesGateWeb.Observations.subscribe(socket, &__MODULE__.refresh_observations/1)

    if connected?(socket) do
      Process.send_after(self(), :check_login, 1000)
    end

    projection = NervesGateWeb.Backend.status()
    name = hostname(projection.remote_access)

    {:ok,
     assign(socket,
       projection: projection,
       form: to_form(%{"hostname" => name}, as: :remote),
       base: name,
       dirty: false,
       pending_name: nil,
       message: nil,
       login_requested: false,
       login_url: nil,
       disconnecting: false
     )}
  end

  def handle_event("change", %{"remote" => %{"hostname" => name}}, socket),
    do:
      {:noreply,
       assign(socket,
         form: to_form(%{"hostname" => name}, as: :remote),
         dirty: true,
         message: nil
       )}

  def handle_event("save", %{"remote" => params}, socket) do
    projection = NervesGateWeb.Backend.status()
    online = projection.remote_access.state == "online"

    socket =
      assign(socket, form: to_form(Map.take(params, ["hostname"]), as: :remote), dirty: true)

    if socket.assigns.base != hostname(projection.remote_access) do
      {:noreply,
       assign(socket,
         message: "The device name changed in another session. Reload before saving."
       )}
    else
      result =
        if online do
          NervesGateWeb.Backend.remote_configure(params["hostname"])
        else
          NervesGateWeb.Backend.remote_connect(params["hostname"])
        end

      socket =
        if result == :ok do
          assign(socket,
            pending_name: String.downcase(params["hostname"]),
            login_requested: not online,
            login_url: nil
          )
        else
          socket
        end

      reply(socket, result)
    end
  end

  def handle_event("ask-disconnect", _, socket),
    do: {:noreply, assign(socket, disconnecting: true)}

  def handle_event("cancel-disconnect", _, socket),
    do: {:noreply, assign(socket, disconnecting: false)}

  def handle_event("disconnect", _, socket) do
    reply(
      assign(socket, disconnecting: false, login_requested: false, login_url: nil),
      NervesGateWeb.Backend.remote_disconnect()
    )
  end

  @doc false
  def refresh_observations(socket) do
    refresh(socket, NervesGateWeb.Backend.status())
  end

  def handle_info(:check_login, socket) do
    Process.send_after(self(), :check_login, 1000)

    socket =
      if socket.assigns.login_requested do
        refresh(socket, NervesGateWeb.Backend.status())
      else
        socket
      end

    {:noreply, socket}
  end

  defp reply(socket, :ok) do
    {:noreply, refresh(assign(socket, message: nil), NervesGateWeb.Backend.status())}
  end

  defp reply(socket, {:error, error}) do
    {:noreply, refresh(assign(socket, message: error.message), NervesGateWeb.Backend.status())}
  end

  defp refresh(socket, projection) do
    socket
    |> assign(projection: projection)
    |> refresh_name(projection.remote_access)
    |> refresh_login(projection.remote_access)
  end

  defp refresh_name(socket, remote) do
    name = hostname(remote)

    cond do
      socket.assigns.pending_name == name ->
        accept_name(socket, name)

      not socket.assigns.dirty ->
        assign(socket, form: to_form(%{"hostname" => name}, as: :remote), base: name)

      remote.operation == nil ->
        assign(socket, pending_name: nil)

      true ->
        socket
    end
  end

  defp accept_name(socket, name) do
    unchanged = String.downcase(socket.assigns.form.params["hostname"] || "") == name
    socket = assign(socket, base: name, pending_name: nil, dirty: not unchanged)

    if unchanged do
      assign(socket, form: to_form(%{"hostname" => name}, as: :remote))
    else
      socket
    end
  end

  defp refresh_login(socket, remote) do
    cond do
      not remote.available or remote.state == "online" or remote.error != nil ->
        assign(socket, login_url: nil, login_requested: false)

      remote.operation == "connect" ->
        socket

      remote.auth_state not in ["authenticating", "needs_login"] ->
        assign(socket, login_url: nil, login_requested: false)

      socket.assigns.login_requested and remote.operation == nil ->
        read_login_url(socket)

      true ->
        socket
    end
  end

  defp read_login_url(socket) do
    case NervesGateWeb.Backend.remote_login_url() do
      {:ok, url} -> assign(socket, login_url: url)
      _ -> assign(socket, login_url: nil)
    end
  end

  def render(assigns) do
    assigns = assign(assigns, remote: assigns.projection.remote_access)

    ~H"""
    <.link navigate="/" class="ui-text-link">Back to Overview</.link>
    <.page_header
      title="Remote access"
      description="Connect this gateway to your private network."
    />
    <.notice :if={@remote.simulated}>
      Development preview. Tailscale is simulated; your computer’s VPN is never changed.
    </.notice>
    <.notice :if={@message} tone="warning" role="alert">{@message}</.notice>
    <RemoteStatus.connection remote={@remote} title="Connection">
      <.notice :if={@login_url}>
        <p>Open Tailscale to sign in, then return here. Keep this login link private.</p>
        <.button
          id="tailscale-login-link"
          href={@login_url}
          target="_blank"
          rel="noopener noreferrer"
          referrerpolicy="no-referrer"
        >Continue in Tailscale</.button>
      </.notice>
      <div id="tailscale-settings" class="ui-stack">
        <.form for={@form} id="tailscale-form" phx-change="change" phx-submit="save" class="ui-stack">
          <.field
            field={@form[:hostname]}
            label="Device name"
            help="The name shown in your Tailscale account."
            disabled={@remote.operation != nil}
            required
            autocomplete="off"
          />
          <div class="ui-actions">
            <.button
              id="tailscale-save"
              type="submit"
              disabled={
                !@projection.actions[
                  if(@remote.state == "online", do: "remote.configure", else: "remote.connect")
                ].enabled
              }
              phx-disable-with="Working…"
            >{if @remote.state == "online", do: "Save device name", else: "Connect Tailscale"}</.button>
            <.button
              :if={
                @remote.state == "online" or
                  @remote.auth_state in ["authenticating", "needs_approval"]
              }
              variant="secondary"
              phx-click="ask-disconnect"
              disabled={!@projection.actions["remote.disconnect"].enabled}
            >Disconnect</.button>
          </div>
        </.form>
        <.notice :if={@disconnecting} tone="warning" role="alert">
          <p>
            Disconnect this gateway from Tailscale? If you’re using Tailscale now, you’ll lose this page. Enrollment and settings are kept for reconnecting. USB and local access stay available.
          </p>
          <div class="ui-actions">
            <.button phx-click="disconnect">Disconnect Tailscale</.button><.button
              variant="secondary"
              phx-click="cancel-disconnect"
            >Cancel</.button>
          </div>
        </.notice>
      </div>
      <p>
        <a
          href="https://login.tailscale.com/admin/machines"
          target="_blank"
          rel="noopener noreferrer"
          class="ui-text-link"
        >Open Tailscale admin console</a>
      </p>
    </RemoteStatus.connection>
    <p class="ui-help">
      To share an equipment subnet, open its <.link navigate="/equipment" class="ui-text-link">LAN connection</.link>.
    </p>
    <details
      id="tailscale-details"
      class="ui-details"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
    >
      <summary>Connection details</summary>
      <p :if={@remote.version} class="ui-help">Tailscale {@remote.version}</p>
      <p :if={@remote.advertised_routes not in [nil, []]} class="ui-help">
        Advertised routes: {Enum.join(@remote.advertised_routes, ", ")}. Advertisement does not prove approval or reachability.
      </p>
      <p class="ui-help">
        Existing identity, routes and sharing settings are preserved. Restrict access to port 4000 with your Tailscale policy.
      </p>
    </details>
    """
  end

  defp hostname(remote),
    do: if(remote.hostname in [nil, ""], do: "nerves-gate", else: remote.hostname)
end
