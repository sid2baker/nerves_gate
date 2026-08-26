defmodule NervesGateWeb.StatusLive do
  @moduledoc false

  use NervesGateWeb, :live_view

  alias NervesGateWeb.Presence
  alias NervesGateWeb.StatusLive.Render
  alias NervesGateWeb.StatusLive.View

  @impl true
  def mount(_params, web_session, socket) do
    {:ok, session, fleet} = NervesGate.connect()

    if NervesGate.configured?(session) do
      mount_dashboard(session, fleet, web_session, socket)
    else
      :ok = NervesGate.disconnect(session)
      {:ok, redirect(socket, to: ~p"/commissioning")}
    end
  end

  defp mount_dashboard(session, fleet, web_session, socket) do
    model = dashboard_model(fleet)
    remote_ip = Map.get(web_session, "remote_ip", "unknown")

    socket =
      socket
      |> assign(
        dashboard_access: Map.get(web_session, "dashboard_access", false),
        selected_device_id: model.local.id,
        presence_tracked: false
      )
      |> assign_private(
        fleet: fleet,
        actor: NervesGate.actor_for_ip(session, remote_ip),
        session: session,
        session_monitor: Process.monitor(session)
      )
      |> assign_view()
      |> maybe_track_presence()

    {:ok, socket}
  end

  @impl true
  defdelegate render(assigns), to: Render

  @doc false
  defdelegate dashboard(assigns), to: Render

  @impl true
  def handle_event("select-node", %{"device-id" => device_id}, socket) do
    {:noreply, socket |> assign(:selected_device_id, device_id) |> assign_view()}
  end

  def handle_event("enable-subnet-router", %{"subnet_router" => params}, socket) do
    routes = params |> Map.get("routes", "") |> parse_routes()

    case NervesGate.configure_subnet_router(true, routes) do
      {:ok, _subnet_router} ->
        {:noreply,
         socket
         |> put_flash(:info, "Subnet router enabled.")
         |> refresh_from_session()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, subnet_router_error(reason))
         |> refresh_from_session()}
    end
  end

  def handle_event("disable-subnet-router", _params, socket) do
    case NervesGate.configure_subnet_router(false, []) do
      {:ok, _subnet_router} ->
        {:noreply,
         socket
         |> put_flash(:info, "Subnet router disabled. Remote gateway access is unchanged.")
         |> refresh_from_session()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, subnet_router_error(reason))
         |> refresh_from_session()}
    end
  end

  def handle_event("enable-ssh", _params, socket) do
    case NervesGate.configure_ssh(true) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Remote IEx enabled for Tailnet clients.")
         |> refresh_from_session()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, ssh_error(reason))}
    end
  end

  def handle_event("disable-ssh", _params, socket) do
    case NervesGate.configure_ssh(false) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Remote IEx disabled.")
         |> refresh_from_session()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, ssh_error(reason))}
    end
  end

  @impl true
  def handle_info(
        {:nerves_gate_state_changed, session, fleet},
        %{private: %{session: session}} = socket
      ) do
    {:noreply, refresh_dashboard(socket, fleet)}
  end

  def handle_info(
        {:DOWN, reference, :process, session, _reason},
        %{private: %{session: session, session_monitor: reference}} = socket
      ) do
    {:stop, :nerves_gate_session_stopped, socket}
  end

  def handle_info(_presence_event, socket) do
    {:noreply, refresh_dashboard(socket)}
  end

  defp refresh_from_session(socket) do
    refresh_dashboard(socket, NervesGate.state(socket.private.session))
  end

  defp refresh_dashboard(socket), do: refresh_dashboard(socket, socket.private.fleet)

  defp refresh_dashboard(socket, fleet) do
    socket
    |> assign_private(fleet: fleet)
    |> assign_view()
    |> maybe_track_presence()
  end

  defp dashboard_model(fleet), do: View.build(fleet, Presence.count(), nil)

  defp assign_view(socket) do
    view = View.build(socket.private.fleet, Presence.count(), socket.assigns.selected_device_id)
    assign(socket, view: view)
  end

  defp maybe_track_presence(socket) do
    if connected?(socket) and socket.assigns.dashboard_access and
         socket.assigns.view.configuration.configured and not socket.assigns.presence_tracked do
      Phoenix.PubSub.subscribe(NervesGate.PubSub, Presence.topic())
      Presence.track_visitor(self(), socket.private.actor)
      socket |> assign(:presence_tracked, true) |> refresh_dashboard()
    else
      socket
    end
  end

  defp parse_routes(value) when is_binary(value) do
    value
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.uniq()
  end

  defp parse_routes(_value), do: []

  defp subnet_router_error(:subnet_routes_required), do: "Enter at least one subnet route."

  defp subnet_router_error(:configuration_change_in_progress),
    do: "Finish or reject the remote-access change before editing subnet routes."

  defp subnet_router_error(:invalid_subnet_routes),
    do: "Enter valid IPv4 or IPv6 CIDRs separated by commas or spaces."

  defp subnet_router_error({:subnet_router_apply_failed, _reason}),
    do:
      "Routes were saved but could not be applied yet. The gateway will retry without changing remote access."

  defp subnet_router_error(_reason),
    do: "The subnet-router change could not be applied. Remote gateway access is unchanged."

  defp ssh_error(:configuration_change_in_progress),
    do: "Finish or reject the remote-access change before changing Remote IEx."

  defp ssh_error(_reason), do: "Remote IEx could not be changed."

  defp assign_private(socket, assigns) do
    Enum.reduce(assigns, socket, fn {key, value}, socket ->
      put_in(socket.private[key], value)
    end)
  end
end
