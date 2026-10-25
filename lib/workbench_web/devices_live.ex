defmodule WorkbenchWeb.DevicesLive do
  @moduledoc "One directory for unverified network gateways and owned simulated devices."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import WorkbenchWeb.Components
  alias Scenarios.Runner

  def mount(_, _, socket) do
    if connected?(socket) do
      Runner.subscribe()
      Workbench.LANDiscovery.refresh()
      Process.send_after(self(), :directory, 500)
    end

    {:ok, socket |> assign(kind: "all", query: "") |> refresh()}
  end

  def handle_params(params, _, socket) do
    kind = if params["kind"] in ["physical", "simulated"], do: params["kind"], else: "all"
    {:noreply, assign(socket, kind: kind, query: params["q"] || "")}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply,
     push_patch(socket,
       to: "/devices?" <> URI.encode_query(%{kind: socket.assigns.kind, q: query})
     )}
  end

  def handle_event("discover", _, socket), do: command(socket, Workbench.LANDiscovery.refresh())

  def handle_event("retry_info", %{"address" => address}, socket),
    do: command(socket, Workbench.Operations.start("device_info", address))

  def handle_event("add_address", %{"address" => address}, socket),
    do: command(socket, Workbench.LANDiscovery.add(address))

  def handle_info(:directory, socket) do
    Process.send_after(self(), :directory, 500)
    {:noreply, refresh(socket)}
  end

  def handle_info({:scenarios, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    discovery = Workbench.LANDiscovery.snapshot()

    assign(socket,
      discovery: discovery,
      devices: Workbench.Devices.list(Runner.snapshot(), discovery)
    )
  end

  defp command(socket, :ok), do: {:noreply, socket |> assign(:error, nil) |> refresh()}
  defp command(socket, {:error, message}), do: {:noreply, assign(socket, :error, message)}

  def render(assigns) do
    assigns =
      assign(
        assigns,
        :filtered,
        Workbench.Devices.filter(assigns.devices, assigns.kind, assigns.query)
      )

    ~H"""
    <main class="ui-main ui-stack bench" id="devices-page">
      <.page_header
        eyebrow="Developer workbench"
        title="Devices"
        description="Physical gateways and owned QEMU devices, in one place."
      >
        <:actions>
          <.button phx-click="discover" disabled={@discovery.status == :searching}>Refresh discovery</.button>
          <.link
            navigate="/develop/firmware#simulator-lifecycle"
            class="ui-button ui-button--secondary"
          >Set up QEMU</.link>
        </:actions>
      </.page_header>
      <.notice :if={@discovery.error} tone="warning">{@discovery.error}</.notice>
      <div class="dev-list-toolbar">
        <nav class="dev-filters" aria-label="Device type">
          <.link
            :for={
              {kind, label} <- [{"all", "All"}, {"physical", "Physical"}, {"simulated", "Simulated"}]
            }
            patch={"/devices?" <> URI.encode_query(%{kind: kind, q: @query})}
            aria-current={if @kind == kind, do: "page"}
          >{label}</.link>
        </nav>
        <form id="device-search" phx-change="search" phx-submit="search">
          <input
            type="search"
            name="q"
            value={@query}
            phx-debounce="200"
            placeholder="Search devices…"
            aria-label="Search devices"
          />
        </form>
      </div>
      <div class="ui-panel dev-table-wrap">
        <table class="dev-device-table" id="device-directory">
          <caption class="ui-help">
            {length(@filtered)} devices · discovery {@discovery.status}
          </caption>
          <thead>
            <tr>
              <th scope="col">Device</th><th scope="col">Type</th><th scope="col">State</th><th scope="col">
                Target
              </th><th scope="col">Firmware</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={device <- @filtered} data-device-kind={device.kind}>
              <td>
                <.link navigate={device.path} class="ui-text-link">{device.name}</.link><p
                  :if={device.name != device.address}
                  class="ui-help"
                >
                  {device.address}
                </p>
              </td>
              <td><.device_kind kind={device.kind} /></td>
              <td>
                {device.status}
                <div :if={device[:info_read] && device.info_read.status == :failed}>
                  <p class="ui-help">{device.info_read.message}</p>
                  <.button
                    variant="quiet"
                    phx-click="retry_info"
                    phx-value-address={device.address}
                    disabled={@operation.status == :running}
                  >Retry information read</.button>
                </div>
              </td><td>{device.target || "Unknown"}</td><td>
                {device.version || "Unknown"}
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={@filtered == []} class="dev-empty">
          No devices match. Add a gateway URL, refresh LAN and tailnet discovery, or set up QEMU.
        </p>
      </div>
      <.panel title="Add a physical gateway" icon="network" id="network-devices">
        <form id="add-address" phx-submit="add_address" class="ui-actions">
          <input
            type="text"
            name="address"
            aria-label="Gateway URL, hostname or IPv4 address"
            placeholder="https://nerves-gate.example.ts.net"
            required
          />
          <.button type="submit" variant="secondary">Add address</.button>
        </form>
        <p class="ui-help">
          Discovery reads LAN mDNS and online tailnet peers named nerves-gate (or nerves-gate-*). Candidates are unverified, not proof of gateway identity or HTTPS availability. Other names can be added manually. Use a root HTTPS URL for Tailscale Serve; bare hosts default to HTTP port 4000. No subnet scans or VPN changes. Each new candidate gets one read-only SSH information attempt with verified host keys and public-key authentication. Failed reads require an explicit Retry.
        </p>
      </.panel>
    </main>
    """
  end
end
