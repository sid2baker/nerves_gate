defmodule NervesGateWeb.DashboardLive do
  use Phoenix.LiveView
  alias NervesGate.Device
  import NervesGateWeb.NetworkStatus

  def mount(_, _, socket) do
    subscribe(socket, Device.topic(), &__MODULE__.handle_device/2)

    {:ok, assign(socket, projection: Device.projection())}
  end

  @doc false
  def handle_device({:device, _projection}, socket) do
    # A queued notification may predate a command reply; query current state.
    assign(socket, projection: Device.projection())
  end

  def render(assigns) do
    ~H"""
    <h1 class="text-3xl font-bold">Your local network</h1>
    <p class="alert alert-warning hidden phx-disconnected:block">
      Connection lost — displayed status may be out of date.
    </p>
    <p :if={@projection.network.pending} class="alert alert-warning">
      Settings are being tried, not yet saved. <a href="/setup" class="link">Confirm or restore them</a>.
    </p>
    <.topology status={@projection.network} />
    <section class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <h2 class="card-title">Local access</h2>
        <p :if={@projection.network.desired}>
          Saved address assignment: {if @projection.network.desired["ip_method"] == "dhcp",
            do: "Automatic (DHCP)",
            else: @projection.network.desired["static_ip"]}
        </p>
        <p>Both Ethernet ports share one network. No DHCP server or Ethernet-to-Ethernet NAT.</p>
        <a href="/setup" class="btn btn-primary w-fit">Open guided setup</a>
      </div>
    </section>
    <section class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <h2 class="card-title">Firmware</h2>
        <p>Firmware {@projection.system.firmware} · {@projection.system.target}</p>
        <p>Browser firmware uploads will be available in a later milestone.</p>
      </div>
    </section>
    """
  end
end
