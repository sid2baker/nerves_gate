defmodule NervesGateWeb.StatusLive do
  @moduledoc false

  use NervesGateWeb, :live_view

  alias NervesGate.Device
  alias NervesGate.DeviceState.Client
  alias NervesGate.DeviceState.Data
  alias NervesGate.DeviceState.Server
  alias NervesGate.Identity
  alias NervesGate.Internet.Monitor
  alias NervesGate.Setup
  alias NervesGate.Tailnet.Observer
  alias NervesGateWeb.Presence
  alias NervesGateWeb.StatusLive.Render
  alias NervesGateWeb.StatusLive.View

  @context_topics ~w(setup device internet)

  @impl true
  def mount(_params, session, socket) do
    remote_ip = Map.get(session, "remote_ip", "unknown")
    tailnet_access = Map.get(session, "tailnet_access", false)
    actor = Observer.actor_for_ip(remote_ip)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(NervesGate.PubSub, "device_state")
      Enum.each(@context_topics, &Phoenix.PubSub.subscribe(NervesGate.PubSub, &1))
    end

    {:ok, snapshot} =
      if connected?(socket), do: Server.join(self()), else: {:ok, Server.snapshot()}

    state = %{
      data: snapshot.data,
      boot_id: snapshot.boot_id,
      revision: snapshot.revision,
      replicas: Client.replicas()
    }

    context = load_context()

    socket =
      socket
      |> assign(
        tailnet_access: tailnet_access,
        selected_device_id: state.data.device_id,
        presence_tracked: false
      )
      |> assign_private(state: state, context: context, actor: actor)
      |> assign_view()
      |> maybe_track_presence()

    {:ok, socket}
  end

  @impl true
  defdelegate render(assigns), to: Render

  @doc false
  defdelegate dashboard(assigns), to: Render

  @impl true
  def handle_event("configure-internet", %{"internet" => params}, socket) do
    case Setup.configure_internet(params) do
      {:ok, _phase} -> setup_ok(socket, "Internet verified and saved.")
      {:error, reason} -> setup_error(socket, "Internet setup failed: #{format_error(reason)}")
    end
  end

  def handle_event("configure-tailscale", %{"auth_token" => token}, socket) do
    case Setup.configure_tailscale(token) do
      {:ok, :cluster} -> setup_ok(socket, "Tailnet enrollment completed.")
      {:error, reason} -> setup_error(socket, "Tailnet setup failed: #{format_error(reason)}")
    end
  end

  def handle_event("configure-cluster", params, socket) do
    cookie = params |> get_in(["cluster", "cookie"]) |> blank_to_nil()

    case Setup.configure_cluster(cookie) do
      {:ok, :ready} -> setup_ok(socket, "Gateway setup completed.")
      {:error, reason} -> setup_error(socket, "Cluster setup failed: #{format_error(reason)}")
    end
  end

  def handle_event("rename-device", %{"device" => %{"name" => name}}, socket) do
    case Device.rename(name, socket.private.actor) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Device name saved.") |> refresh_context()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Name must contain 1–80 printable characters.")}
    end
  end

  def handle_event("select-node", %{"device-id" => device_id}, socket) do
    {:noreply, socket |> assign(:selected_device_id, device_id) |> assign_view()}
  end

  def handle_event("enable-recovery", _params, socket) do
    :ok = Setup.enable_recovery_access(:local_action)

    {:noreply,
     socket
     |> put_flash(:info, "Local recovery access is being enabled.")
     |> refresh_context()}
  end

  @impl true
  def handle_info(
        {:device_state_operation, _owner_node, boot_id, revision, operation},
        socket
      ) do
    {:noreply, apply_operation(socket, boot_id, revision, operation)}
  end

  def handle_info({:local_state_changed, data}, socket) do
    if data == socket.private.state.data,
      do: {:noreply, socket},
      else: {:noreply, rejoin_local(socket)}
  end

  def handle_info({:replica_changed, _device_id, _replica}, socket) do
    state = %{socket.private.state | replicas: Client.replicas()}
    {:noreply, socket |> assign_private(state: state) |> assign_view()}
  end

  def handle_info(_context_or_presence_event, socket) do
    {:noreply, refresh_context(socket)}
  end

  defp apply_operation(socket, boot_id, revision, operation) do
    state = socket.private.state

    case operation_position(state, boot_id, revision) do
      :next -> apply_next_operation(socket, state, revision, operation)
      :duplicate -> socket
      :resync -> rejoin_local(socket)
    end
  end

  defp apply_next_operation(socket, state, revision, operation) do
    case Data.apply_operation(state.data, operation) do
      {:ok, data, _actions} ->
        state = %{state | data: data, revision: revision}
        socket |> assign_private(state: state) |> assign_view()

      :error ->
        rejoin_local(socket)
    end
  end

  defp operation_position(%{boot_id: boot_id, revision: current}, boot_id, revision)
       when revision == current + 1,
       do: :next

  defp operation_position(%{boot_id: boot_id, revision: current}, boot_id, revision)
       when revision <= current,
       do: :duplicate

  defp operation_position(_state, _boot_id, _revision), do: :resync

  defp rejoin_local(socket) do
    {:ok, snapshot} = Server.join(self())

    state = %{
      data: snapshot.data,
      boot_id: snapshot.boot_id,
      revision: snapshot.revision,
      replicas: Client.replicas()
    }

    socket |> assign_private(state: state) |> assign_view()
  end

  defp setup_ok(socket, message) do
    {:noreply, socket |> put_flash(:info, message) |> refresh_context()}
  end

  defp setup_error(socket, message), do: {:noreply, put_flash(socket, :error, message)}

  defp refresh_context(socket) do
    socket
    |> assign_private(context: load_context())
    |> assign_view()
    |> maybe_track_presence()
  end

  defp assign_view(socket) do
    view =
      View.build(
        socket.private.state,
        socket.private.context,
        socket.assigns.selected_device_id
      )

    assign(socket, view: view)
  end

  defp maybe_track_presence(socket) do
    if connected?(socket) and socket.assigns.tailnet_access and socket.assigns.view.setup.ready and
         not socket.assigns.presence_tracked do
      Phoenix.PubSub.subscribe(NervesGate.PubSub, Presence.topic())
      Presence.track_visitor(self(), socket.private.actor)
      socket |> assign(:presence_tracked, true) |> refresh_people_count()
    else
      socket
    end
  end

  defp refresh_people_count(socket) do
    context = Map.put(socket.private.context, :people_count, Presence.count())
    socket |> assign_private(context: context) |> assign_view()
  end

  defp load_context do
    %{
      setup: Setup.status(),
      profile: Device.get(),
      identity: Identity.get(),
      internet: Monitor.status(),
      people_count: Presence.count(),
      diagnostics: diagnostics()
    }
  end

  defp diagnostics do
    {uptime, _since_last_call} = :erlang.statistics(:wall_clock)

    %{
      target: Nerves.Runtime.mix_target(),
      uptime_seconds: div(uptime, 1_000),
      otp_release: List.to_string(:erlang.system_info(:otp_release)),
      memory_bytes: :erlang.memory(:total)
    }
  end

  defp assign_private(socket, assigns) do
    Enum.reduce(assigns, socket, fn {key, value}, socket ->
      put_in(socket.private[key], value)
    end)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp format_error(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ")

  defp format_error(reason) when is_map(reason) do
    Enum.map_join(reason, ", ", fn {field, message} -> "#{field} #{message}" end)
  end

  defp format_error(_reason), do: "operation failed"
end
