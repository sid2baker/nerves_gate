defmodule NervesGateWeb.CommissioningLive do
  @moduledoc "Owns the persisted first-run commissioning workflow."

  use NervesGateWeb, :live_view

  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.DeviceState.Server
  alias NervesGate.Setup
  alias NervesGateWeb.FormHelpers
  alias NervesGateWeb.SetupComponents

  @topics ~w(setup internet tailnet cluster device_state)

  @impl true
  def mount(_params, _session, socket) do
    setup = Setup.status()

    if setup.ready do
      {:ok, redirect(socket, to: ~p"/")}
    else
      if connected?(socket),
        do: Enum.each(@topics, &Phoenix.PubSub.subscribe(NervesGate.PubSub, &1))

      {:ok, assign_view(socket)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <SetupComponents.current view={@view} flash={@flash} />
    """
  end

  @impl true
  def handle_event("configure-internet", %{"internet" => params}, socket) do
    case Setup.configure_internet(params) do
      {:ok, _phase} ->
        setup_ok(socket, "Internet verified and saved.")

      {:error, reason} ->
        setup_error(socket, "Internet setup failed: #{FormHelpers.format_error(reason)}")
    end
  end

  def handle_event("configure-tailscale", %{"auth_token" => token}, socket) do
    case Setup.configure_tailscale(token) do
      {:ok, _phase} ->
        setup_ok(socket, "Tailnet enrollment completed.")

      {:error, reason} ->
        setup_error(socket, "Tailnet setup failed: #{FormHelpers.format_error(reason)}")
    end
  end

  def handle_event("configure-cluster", params, socket) do
    group = params |> get_in(["cluster", "group"]) |> FormHelpers.blank_to_nil()

    case Setup.configure_cluster(group) do
      {:ok, :ready} ->
        setup_ok(socket, "Gateway commissioning completed and persisted.")

      {:error, reason} ->
        setup_error(socket, "Cluster setup failed: #{FormHelpers.format_error(reason)}")
    end
  end

  @impl true
  def handle_info(_event, socket), do: {:noreply, assign_view(socket)}

  defp assign_view(socket) do
    data = Server.data()
    cluster = ClusterManager.status()

    view = %{
      setup: Setup.status(),
      cluster: cluster,
      local: %{
        data: data,
        url: if(data.tailnet.ipv4, do: "http://#{data.tailnet.ipv4}/", else: nil)
      }
    }

    assign(socket, :view, view)
  end

  defp setup_ok(socket, message) do
    {:noreply, socket |> put_flash(:info, message) |> assign_view()}
  end

  defp setup_error(socket, message), do: {:noreply, put_flash(socket, :error, message)}
end
