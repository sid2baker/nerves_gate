defmodule NervesGateWeb.RemoteLive do
  use Phoenix.LiveView
  alias NervesGate.Device
  import NervesGateWeb.CoreComponents

  def mount(_, _, socket) do
    subscribe(socket, Device.topic(), &__MODULE__.handle_device/2)

    if connected?(socket) do
      Process.send_after(self(), :check_login, 1000)
    end

    projection = Device.projection()
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
    projection = Device.projection()
    online = projection.remote_access.state == "online"

    socket =
      assign(socket, form: to_form(Map.take(params, ["hostname"]), as: :remote), dirty: true)

    if socket.assigns.base != hostname(projection.remote_access) do
      {:noreply,
       assign(socket,
         message: "The device name changed in another session. Reload before saving."
       )}
    else
      action =
        if online do
          "remote.configure"
        else
          "remote.connect"
        end

      result =
        Device.dispatch(action, Map.take(params, ["hostname"]),
          expected_revision: projection.revision
        )

      case result do
        {:ok, _} ->
          socket =
            assign(socket,
              pending_name: String.downcase(params["hostname"]),
              login_requested: not online,
              login_url: nil
            )

          reply(socket, result)

        _ ->
          reply(socket, result)
      end
    end
  end

  def handle_event("ask-disconnect", _, socket),
    do: {:noreply, assign(socket, disconnecting: true)}

  def handle_event("cancel-disconnect", _, socket),
    do: {:noreply, assign(socket, disconnecting: false)}

  def handle_event("disconnect", _, socket) do
    reply(
      assign(socket, disconnecting: false, login_requested: false, login_url: nil),
      Device.dispatch("remote.disconnect")
    )
  end

  @doc false
  def handle_device({:device, _}, socket) do
    refresh(socket, Device.projection())
  end

  def handle_info(:check_login, socket) do
    Process.send_after(self(), :check_login, 1000)

    socket =
      if socket.assigns.login_requested do
        refresh(socket, Device.projection())
      else
        socket
      end

    {:noreply, socket}
  end

  defp reply(socket, {:ok, %{projection: projection}}),
    do: {:noreply, refresh(assign(socket, message: nil), projection)}

  defp reply(socket, {:error, %{error: error, projection: projection}}),
    do: {:noreply, refresh(assign(socket, message: error.message), projection)}

  defp refresh(socket, projection) do
    remote = projection.remote_access
    name = hostname(remote)
    socket = assign(socket, projection: projection)

    socket =
      cond do
        socket.assigns.pending_name == name ->
          unchanged = String.downcase(socket.assigns.form.params["hostname"] || "") == name
          socket = assign(socket, base: name, pending_name: nil, dirty: not unchanged)

          if unchanged do
            assign(socket, form: to_form(%{"hostname" => name}, as: :remote))
          else
            socket
          end

        not socket.assigns.dirty ->
          assign(socket, form: to_form(%{"hostname" => name}, as: :remote), base: name)

        remote.operation == nil ->
          assign(socket, pending_name: nil)

        true ->
          socket
      end

    cond do
      not remote.available or remote.state == "online" or remote.error != nil ->
        assign(socket, login_url: nil, login_requested: false)

      remote.operation == "connect" ->
        socket

      remote.auth_state not in ["authenticating", "needs_login"] ->
        assign(socket, login_url: nil, login_requested: false)

      socket.assigns.login_requested and remote.operation == nil ->
        case Device.dispatch("remote.login_url") do
          {:ok, %{result: %{url: url}}} -> assign(socket, login_url: url)
          _ -> assign(socket, login_url: nil)
        end

      true ->
        socket
    end
  end

  def render(assigns) do
    assigns = assign(assigns, remote: assigns.projection.remote_access)

    ~H"""
    <.page_header title="Tailscale" description="Connect this gateway to your private network." />
    <div class="ui-disconnected">
      <.notice tone="warning" role="alert">
        Connection lost. Reconnect locally or through USB to check Tailscale.
      </.notice>
    </div>
    <.notice :if={@remote.simulated}>
      Development preview. Tailscale is simulated; your computer’s VPN is never changed.
    </.notice>
    <.notice :if={@message} tone="warning" role="alert">{@message}</.notice>
    <.notice :if={@remote.error} tone="warning" role="alert">{@remote.error.message}</.notice>
    <.notice :if={@remote.auth_state == "error" and @remote.error == nil} tone="warning" role="alert">
      Tailscale sign-in failed. Check your Internet connection and try connecting again.
    </.notice>
    <.panel title="Private connection" icon="shield">
      <:meta>
        <.status tone={if @remote.state == "online", do: "good", else: "neutral"}>
          {status_label(@remote)}
        </.status>
      </:meta>
      <p :if={!@remote.available}>
        Tailscale is starting or unavailable. Check that the daemon is installed and the gateway has Internet access.
      </p>
      <p :if={@remote.auth_state == "needs_approval"} role="status">
        Approve this gateway in your Tailscale admin console. This page updates automatically.
      </p>
      <p :if={@remote.operation} role="status">{operation(@remote.operation)}</p>
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
      <div :if={@remote.state == "online"} class="ui-settings-list">
        <.setting_row label="Tailscale address">
          {@remote.ipv4 || "Waiting for an address"}
        </.setting_row>
        <.setting_row :if={@remote.dns_name} label="DNS name">{@remote.dns_name}</.setting_row>
      </div>
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
                @remote.auth_state in ["authenticating", "needs_approval", "stopped"]
            }
            variant="secondary"
            phx-click="ask-disconnect"
            disabled={!@projection.actions["remote.disconnect"].enabled}
          >Disconnect</.button>
        </div>
      </.form>
      <.notice :if={@disconnecting} tone="warning" role="alert">
        <p>
          Disconnect this gateway from Tailscale? If you’re using Tailscale now, you’ll lose this page. USB and local access stay available.
        </p>
        <div class="ui-actions">
          <.button phx-click="disconnect">Disconnect Tailscale</.button><.button
            variant="secondary"
            phx-click="cancel-disconnect"
          >Cancel</.button>
        </div>
      </.notice>
      <p>
        <a
          href="https://login.tailscale.com/admin/machines"
          target="_blank"
          rel="noopener noreferrer"
          class="ui-text-link"
        >Open Tailscale admin console</a>
      </p>
      <p class="ui-help">
        Tailscale keeps its own saved identity. DNS stays managed by the gateway. No auth key is needed.
      </p>
      <p :if={@remote.version} class="ui-help">Daemon {@remote.version}</p>
    </.panel>
    <.panel title="Equipment access" icon="equipment">
      <p>
        This connects the gateway itself. Sharing equipment networks and verifying remote equipment access are separate; this page does not enable subnet routing.
      </p>
      <p :if={@remote.advertised_routes not in [nil, []]} class="ui-help">
        Existing advertised routes: {Enum.join(@remote.advertised_routes, ", ")}. They are left unchanged; advertisement does not prove approval or reachability.
      </p>
      <p class="ui-help">
        The web interface has no authentication yet. Anyone allowed to reach port 4000 can change settings. Restrict access with your Tailscale policy.
      </p>
    </.panel>
    <.panel :if={@remote.health != []} title="Tailscale needs attention" icon="info">
      <p :for={warning <- @remote.health}>{warning}</p>
    </.panel>
    """
  end

  defp hostname(remote),
    do: if(remote.hostname in [nil, ""], do: "nerves-gate", else: remote.hostname)

  defp status_label(%{state: "online"}) do
    "Connected"
  end

  defp status_label(%{auth_state: "needs_approval"}) do
    "Waiting for approval"
  end

  defp status_label(%{auth_state: "authenticating"}) do
    "Waiting for sign-in"
  end

  defp status_label(%{available: false}) do
    "Unavailable"
  end

  defp status_label(_) do
    "Not connected"
  end

  defp operation("connect"), do: "Connecting to Tailscale…"
  defp operation("disconnect"), do: "Disconnecting…"
  defp operation(_), do: "Saving device name…"
end
