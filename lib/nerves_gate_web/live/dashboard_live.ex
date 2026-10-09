defmodule NervesGateWeb.DashboardLive do
  use Phoenix.LiveView
  alias NervesGate.Network
  import NervesGateWeb.NetworkStatus

  def mount(_, _, socket) do
    if connected?(socket), do: Network.subscribe()
    {:ok, assign(socket, status: Network.status())}
  end

  def handle_info({:network, status}, socket), do: {:noreply, assign(socket, status: status)}

  def render(assigns) do
    ~H"""
    <h1 class="text-3xl font-bold">Your local network</h1>
    <p class="alert alert-warning hidden phx-disconnected:block">
      Connection lost — displayed status may be out of date.
    </p>
    <p :if={@status.trial} class="alert alert-warning">
      Settings are being tried, not yet saved. <a href="/setup" class="link">Confirm or restore them</a>.
    </p>
    <.topology status={@status} />
    <section class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <h2 class="card-title">Local access</h2>
        <p :if={@status.config}>
          Saved address assignment: {if @status.config["network"]["ip_method"] == "dhcp",
            do: "Automatic (DHCP)",
            else: @status.config["network"]["static_ip"]}
        </p>
        <p>Both Ethernet ports share one network. No DHCP server or Ethernet-to-Ethernet NAT.</p>
        <a href="/setup" class="btn btn-primary w-fit">Open guided setup</a>
      </div>
    </section>
    <section class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <h2 class="card-title">Firmware</h2>
        <p>Firmware {NervesGate.version()} · {NervesGate.target()}</p>
        <p>Browser firmware uploads will be available in a later milestone.</p>
      </div>
    </section>
    """
  end
end
