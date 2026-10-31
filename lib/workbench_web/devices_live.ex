defmodule WorkbenchWeb.DevicesLive do
  @moduledoc "The gateway directory: every connected or last-seen gateway, live by subscription."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import WorkbenchWeb.Components
  import WorkbenchWeb.Live, only: [command: 2]

  def mount(_, _, socket) do
    if connected?(socket), do: Workbench.Gateways.subscribe()
    {:ok, assign(socket, gateways: Workbench.Gateways.list())}
  end

  def handle_info({:gateways, gateways}, socket),
    do: {:noreply, assign(socket, :gateways, gateways)}

  def handle_event("add", %{"address" => address}, socket),
    do: command(socket, Workbench.Gateways.add(address))

  def handle_event("refresh", _, socket), do: command(socket, Workbench.Gateways.refresh())

  def render(assigns) do
    ~H"""
    <main class="ui-main ui-stack bench" id="devices-page">
      <.page_header
        eyebrow="Devices"
        title="Gateways"
        description="Every Nerves Gate node this Workbench connected to with the development cookie: simulated and physical alike."
      >
        <:actions>
          <.button phx-click="refresh" variant="secondary">Discover now</.button>
        </:actions>
      </.page_header>
      <.panel title="Gateways" icon="network" id="gateways">
        <p :if={@gateways == []} class="ui-help">
          No gateways yet. Start simulated devices, or add a physical gateway's address below.
        </p>
        <div :for={gateway <- @gateways} class="ui-setting-row" id={"gateway-#{gateway.node}"}>
          <div>
            <.link navigate={"/devices/#{gateway.node}"} class="ui-text-link">{gateway.node}</.link>
            <p class="ui-help">
              {gateway.address}
              <span :if={gateway.identity}>
                · {gateway.identity.target} · firmware {gateway.identity.firmware} · serial {gateway.identity.serial}
              </span>
            </p>
          </div>
          <div class="ui-actions">
            <.device_kind source={gateway.source} />
            <.connection gateway={gateway} />
          </div>
        </div>
      </.panel>
      <.panel title="Add a gateway" icon="network">
        <form id="add-gateway" phx-submit="add" class="ui-actions">
          <input
            type="text"
            name="address"
            aria-label="Gateway hostname or IPv4 address"
            placeholder="nerves-gate.example.ts.net"
            required
          />
          <.button type="submit" variant="secondary">Add</.button>
        </form>
        <p class="ui-help">
          LAN mDNS and Tailnet peers tagged tag:nerves-gate are found automatically. A gateway joins once its node accepts the development cookie.
        </p>
        <.link navigate="/provision" class="ui-text-link">Provision a new EC100 or EM300 over USB</.link>
      </.panel>
    </main>
    """
  end
end
