defmodule NervesGateWeb.TailscaleLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  alias NervesGateWeb.{Backend, RemoteStatus}
  alias Phoenix.LiveView.JS

  def mount(_, _, socket) do
    socket = NervesGateWeb.Observations.subscribe(socket, &__MODULE__.refresh_observations/2)
    if connected?(socket), do: Process.send_after(self(), :check_login, 1000)
    name = hostname(socket.assigns.projection.remote_access)

    {:ok,
     assign(socket,
       form: to_form(%{"hostname" => name}, as: :remote),
       base: name,
       dirty: false,
       pending_name: nil,
       request: nil,
       method: "link",
       key_revision: 0,
       login_requested: false,
       login_url: nil,
       login_open: false,
       disconnecting: false
     )}
  end

  # Input-level change events never serialize the secret input with the draft.
  def handle_event("change", %{"remote" => %{"hostname" => name}}, socket),
    do: {:noreply, assign(socket, form: to_form(%{"hostname" => name}, as: :remote), dirty: true)}

  def handle_event("method", %{"remote" => %{"method" => method}}, socket)
      when method in ["link", "auth_key"],
      do:
        {:noreply, assign(socket, method: method, key_revision: socket.assigns.key_revision + 1)}

  def handle_event("save", %{"remote" => params}, socket) do
    remote = Backend.status().remote_access

    socket =
      socket
      |> clear_flash()
      |> assign(
        form: to_form(Map.take(params, ["hostname"]), as: :remote),
        dirty: true,
        key_revision: socket.assigns.key_revision + 1
      )

    cond do
      socket.assigns.request != nil or socket.assigns.login_requested ->
        {:noreply, socket}

      socket.assigns.base != hostname(remote) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The device name changed in another session. Reload before saving."
         )}

      true ->
        submit(socket, remote.state, params)
    end
  end

  def handle_event("show-login", _, socket),
    do: {:noreply, assign(socket, login_open: socket.assigns.login_url != nil)}

  def handle_event("close-login", _, socket),
    do: {:noreply, assign(socket, login_open: false)}

  def handle_event("ask-disconnect", _, socket),
    do: {:noreply, assign(socket, disconnecting: true)}

  def handle_event("cancel-disconnect", _, socket),
    do: {:noreply, assign(socket, disconnecting: false)}

  def handle_event("disconnect", _, socket) do
    socket = socket |> clear_flash() |> assign(disconnecting: false)

    case Backend.remote_disconnect() do
      :ok -> {:noreply, socket |> clear_login() |> assign(request: :disconnect)}
      {:error, error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp submit(socket, state, params) do
    case command(state, socket.assigns.method, params) do
      :ok ->
        {:noreply,
         assign(socket,
           pending_name: String.downcase(params["hostname"]),
           request: if(state == "online", do: :configure, else: :connect),
           login_requested: state != "online" and socket.assigns.method == "link",
           login_url: nil,
           login_open: false
         )}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  defp command("online", _, params), do: Backend.remote_configure(params["hostname"])

  defp command(_, "auth_key", params),
    do: Backend.remote_connect(params["hostname"], auth_key: params["auth_key"])

  defp command(_, "link", params), do: Backend.remote_connect(params["hostname"])

  @doc false
  def refresh_observations(socket, %{backend: %{available: false}} = projection),
    do: socket |> assign(projection: projection, request: nil, pending_name: nil) |> clear_login()

  def refresh_observations(socket, projection) do
    previous = socket.assigns.projection.remote_access
    socket = assign(socket, projection: projection)
    remote = projection.remote_access

    if previous == remote do
      socket
    else
      socket
      |> notify(remote, previous)
      |> refresh_request(remote)
      |> refresh_name(remote, previous)
      |> refresh_login(remote)
    end
  end

  def handle_info(:check_login, socket) do
    Process.send_after(self(), :check_login, 1000)
    {:noreply, read_login(socket, socket.assigns.projection.remote_access)}
  end

  defp notify(socket, %{error: error}, %{error: previous})
       when error != nil and error != previous do
    put_flash(socket, :error, error.message)
  end

  defp notify(socket, %{auth_state: "error"}, %{auth_state: previous}) when previous != "error" do
    put_flash(
      socket,
      :error,
      "Tailscale sign-in failed. Check your connection or auth key and try again."
    )
  end

  defp notify(socket, %{state: "online"}, %{state: previous}) when previous != "online" do
    put_flash(socket, :info, "Connected to Tailscale.")
  end

  defp notify(socket, %{auth_state: "needs_approval"}, %{auth_state: previous})
       when previous != "needs_approval" do
    put_flash(socket, :info, "Approve this gateway in your Tailscale admin console.")
  end

  defp notify(
         %{assigns: %{request: :configure, pending_name: name}} = socket,
         %{operation: nil, error: nil, hostname: name},
         _previous
       ) do
    put_flash(socket, :info, "Device name saved.")
  end

  defp notify(
         %{assigns: %{request: :disconnect}} = socket,
         %{operation: nil, error: nil, auth_state: auth},
         _previous
       )
       when auth in ["stopped", "needs_login"] do
    put_flash(socket, :info, "Disconnected from Tailscale.")
  end

  defp notify(socket, _remote, _previous) do
    socket
  end

  defp refresh_request(socket, remote) do
    finished =
      not remote.available or remote.error != nil or remote.auth_state == "error" or
        (remote.operation == nil and socket.assigns.request in [:configure, :disconnect]) or
        (socket.assigns.request == :connect and
           (remote.state == "online" or remote.auth_state == "needs_approval"))

    if finished, do: assign(socket, request: nil), else: socket
  end

  defp refresh_name(socket, remote, previous) do
    name = hostname(remote)

    cond do
      socket.assigns.pending_name == name and remote.operation == nil ->
        unchanged = String.downcase(socket.assigns.form.params["hostname"] || "") == name
        socket = assign(socket, base: name, pending_name: nil, dirty: not unchanged)

        if unchanged,
          do: assign(socket, form: to_form(%{"hostname" => name}, as: :remote)),
          else: socket

      not socket.assigns.dirty ->
        assign(socket, form: to_form(%{"hostname" => name}, as: :remote), base: name)

      previous.operation != nil and remote.operation == nil ->
        assign(socket, pending_name: nil)

      true ->
        socket
    end
  end

  defp refresh_login(socket, %{available: false}) do
    clear_login(socket)
  end

  defp refresh_login(socket, %{state: "online"}) do
    clear_login(socket)
  end

  defp refresh_login(socket, %{error: error}) when error != nil do
    clear_login(socket)
  end

  defp refresh_login(socket, %{operation: "connect"}), do: socket

  defp refresh_login(socket, %{auth_state: auth})
       when auth in ["error", "needs_approval", "stopped"] do
    clear_login(socket)
  end

  defp refresh_login(socket, remote), do: read_login(socket, remote)

  defp read_login(%{assigns: %{login_requested: true}} = socket, %{
         available: true,
         operation: nil,
         auth_state: auth
       })
       when auth in ["authenticating", "needs_login"] do
    case Backend.remote_login_url() do
      {:ok, url} -> login_url(socket, url)
      _ -> login_url(socket, nil)
    end
  end

  defp read_login(socket, _remote), do: socket

  # Only this requesting LiveView reads the URL. It never enters flash or the projection.
  defp login_url(socket, nil), do: assign(socket, login_url: nil, login_open: false)
  defp login_url(%{assigns: %{login_url: url}} = socket, url), do: socket
  defp login_url(socket, url), do: assign(socket, login_url: url, login_open: true, request: nil)

  defp clear_login(socket),
    do: assign(socket, login_url: nil, login_open: false, login_requested: false)

  def render(assigns) do
    remote = assigns.projection.remote_access
    busy = remote.operation != nil or assigns.request != nil
    assigns = assign(assigns, remote: remote, busy: busy, waiting: assigns.login_requested)

    ~H"""
    <.link navigate="/" class="ui-text-link">Back to Overview</.link>
    <.page_header title="Remote access" description="Connect this gateway to your private network." />
    <RemoteStatus.connection remote={@remote} title="Connection" />
    <.notice :if={@remote.simulated}>
      Development preview. Your computer’s VPN is never changed.
    </.notice>
    <.panel title="Connection settings" id="tailscale-settings">
      <.form for={@form} id="tailscale-form" phx-submit="save" class="ui-stack">
        <.field
          field={@form[:hostname]}
          label="Device name"
          phx-change="change"
          disabled={@busy or @waiting}
          required
          autocomplete="off"
        />
        <div :if={@remote.state != "online"} class="ui-field">
          <label for="remote-method">Connect with</label>
          <select
            id="remote-method"
            name="remote[method]"
            phx-change="method"
            disabled={@busy or @waiting}
          >
            <option value="link" selected={@method == "link"}>Sign-in link</option>
            <option value="auth_key" selected={@method == "auth_key"}>Auth key</option>
          </select>
        </div>
        <div :if={@remote.state != "online" and @method == "auth_key"} class="ui-field">
          <label for={"remote-auth-key-#{@key_revision}"}>Auth key</label>
          <input
            id={"remote-auth-key-#{@key_revision}"}
            type="password"
            name="remote[auth_key]"
            value=""
            required
            maxlength="4096"
            autocomplete="off"
            spellcheck="false"
            disabled={@busy}
            aria-describedby="auth-key-help"
          />
          <p id="auth-key-help" class="ui-help">Used once to connect. Not saved on the gateway.</p>
        </div>
        <div class="ui-actions">
          <.button
            id="tailscale-save"
            type="submit"
            loading={@busy}
            disabled={
              @waiting or
                !@projection.actions[
                  if(@remote.state == "online", do: "remote.configure", else: "remote.connect")
                ].enabled
            }
          >
            {cond do
              @busy -> if @remote.state == "online", do: "Saving…", else: "Connecting…"
              @waiting -> "Waiting for sign-in"
              @remote.state == "online" -> "Save device name"
              true -> "Connect Tailscale"
            end}
          </.button>
          <.button
            :if={@login_url}
            id="tailscale-show-login"
            variant="secondary"
            phx-click="show-login"
          >Show sign-in link</.button>
          <.button
            :if={
              @remote.state == "online" or @waiting or
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
          Disconnect from Tailscale? You’ll lose this page if using Tailscale. Enrollment is kept; local and USB access stay available.
        </p>
        <div class="ui-actions">
          <.button phx-click="disconnect" disabled={!@projection.actions["remote.disconnect"].enabled}>Disconnect Tailscale</.button>
          <.button variant="secondary" phx-click="cancel-disconnect">Cancel</.button>
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
    </.panel>
    <div
      :if={@login_open and @login_url}
      id="tailscale-login-popup"
      class="ui-modal"
      phx-mounted={JS.push_focus() |> JS.focus(to: "#tailscale-login-link")}
      phx-remove={JS.pop_focus()}
    >
      <.focus_wrap
        id="tailscale-login-dialog"
        class="ui-modal-dialog ui-stack"
        role="dialog"
        aria-modal="true"
        aria-labelledby="tailscale-login-title"
        aria-describedby="tailscale-login-help"
        phx-window-keydown="close-login"
        phx-key="Escape"
        phx-click-away="close-login"
      >
        <h2 id="tailscale-login-title">Sign in to Tailscale</h2>
        <p id="tailscale-login-help">Open this private link, sign in, then return here.</p>
        <a
          id="tailscale-login-link"
          href={@login_url}
          target="_blank"
          rel="noopener noreferrer"
          referrerpolicy="no-referrer"
          class="ui-text-link ui-login-link"
        >{@login_url}</a>
        <div class="ui-actions">
          <.button variant="secondary" phx-click="close-login">Close</.button>
        </div>
      </.focus_wrap>
    </div>
    """
  end

  defp hostname(remote),
    do: if(remote.hostname in [nil, ""], do: "nerves-gate", else: remote.hostname)
end
