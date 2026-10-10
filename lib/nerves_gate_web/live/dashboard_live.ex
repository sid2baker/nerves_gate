defmodule NervesGateWeb.DashboardLive do
  use Phoenix.LiveView
  alias NervesGate.Device
  import NervesGateWeb.CoreComponents

  def mount(_, _, socket) do
    subscribe(socket, Device.topic(), &__MODULE__.handle_device/2)
    {:ok, assign(socket, projection: Device.projection())}
  end

  @doc false
  def handle_device({:device, _projection}, socket),
    do: assign(socket, projection: Device.projection())

  def render(assigns) do
    assigns =
      assign(
        assigns,
        :settings,
        if(assigns.projection.network.pending,
          do: assigns.projection.network.pending.network,
          else: assigns.projection.network.desired
        )
      )

    ~H"""
    <div class="ui-disconnected">
      <.notice tone="warning" role="alert">
        Connection lost — displayed status may be out of date.
      </.notice>
    </div>
    <.notice :if={@projection.network.pending} tone="warning" icon="clock">
      Settings are being tried, not yet saved. <a href="/setup" class="ui-text-link">Confirm or restore them</a>.
    </.notice>
    <%= case @live_action do %>
      <% :overview -> %>
        <.page_header
          eyebrow="Overview"
          title="Equipment access at a glance"
          description="Your connections, their status, and what to do next."
        />
        <section class="ui-hero" aria-label="Remote access status">
          <div class="ui-hero-copy">
            <.status tone="warning">Remote access · Not verified</.status>
            <h2>
              {if @projection.network.setup_completed,
                do: "Local connections are saved.",
                else: "Start local. Connect with confidence."}
            </h2>
            <p>
              {if @projection.network.setup_completed,
                do:
                  "Your equipment's remote reachability is still unverified. This build cannot check private-network enrollment or permissions.",
                else:
                  "Choose how your gateway reaches the Internet and connects to equipment. USB keeps setup separate from both."}
            </p>
            <div class="ui-actions">
              <.button href="/setup" icon="arrow">{if @projection.network.setup_completed,
                do: "Review connections",
                else: "Set up connections"}</.button><.button href="/remote" variant="quiet">About remote access</.button>
            </div>
          </div>
          <div class="ui-hero-symbol" aria-hidden="true"><.icon name="shield" /></div>
        </section>
        <div class="ui-content-grid">
          <div class="ui-stack">
            <.live_component
              module={NervesGateWeb.ConnectionPanel}
              id="overview-internet"
              kind={:internet}
            />
            <.panel
              title="Equipment network"
              description="Your devices keep their existing addresses."
              icon="equipment"
            >
              <.status>
                {if @settings && @settings["mode"] != "unconfigured",
                  do: "Network assigned · Reachability unverified",
                  else: "No network assigned"}
              </.status>
              <p class="ui-muted">
                Connecting equipment does not expose it remotely. Network permissions and a check from a remote computer are separate steps.
              </p>
              <:footer>
                <a href="/equipment" class="ui-text-link">Equipment network <.icon name="arrow" /></a>
              </:footer>
            </.panel>
          </div>
          <aside class="ui-stack" aria-label="Connection context">
            <.live_component
              module={NervesGateWeb.ConnectionPanel}
              id="overview-connections"
              kind={:ports}
            />
          </aside>
        </div>
      <% :equipment -> %>
        <.page_header
          eyebrow="Connections"
          title="Equipment"
          description="A local connection to the machines and devices you need."
        />
        <div class="ui-content-grid">
          <div class="ui-stack">
            <.panel
              title="Equipment network"
              icon="equipment"
              description="The gateway joins your existing network."
            >
              <div class="ui-settings-list">
                <.setting_row label="Connection arrangement">{arrangement(@settings)}</.setting_row>
                <.setting_row
                  label="Gateway address"
                  description="This is not your equipment's address."
                >
                  {equipment_address(@settings)}
                </.setting_row>
                <.setting_row label="Device discovery">
                  <.status>Not available yet</.status>
                </.setting_row>
                <.setting_row label="Remote reachability">
                  <.status>Not verified</.status>
                </.setting_row>
              </div>
              <.notice title="Equipment keeps its settings">
                Use an unused gateway address in the existing subnet. No Ethernet DHCP server is started and no remote permissions are changed by this setup.
              </.notice>
              <:footer>
                <.button href="/setup" variant="secondary" icon="arrow">Configure equipment connection</.button>
              </:footer>
            </.panel>
          </div>
          <aside>
            <.live_component
              module={NervesGateWeb.ConnectionPanel}
              id="equipment-connections"
              kind={:ports}
            />
          </aside>
        </div>
      <% :internet -> %>
        <.page_header
          eyebrow="Connections"
          title="Internet & backup"
          description="How your gateway reaches the Internet, and what is verified."
        />
        <div class="ui-content-grid">
          <div class="ui-stack">
            <.live_component
              module={NervesGateWeb.ConnectionPanel}
              id="internet-health"
              kind={:internet}
            />
            <.panel title="Connection settings" icon="settings">
              <.setting_row
                label="Internet source"
                description="Automatic or manual addressing, as set in guided setup."
              >
                {if @settings && @settings["mode"] != "unconfigured",
                  do: "Ethernet",
                  else: "Not assigned"}
              </.setting_row>
              <.notice :if={@settings && @settings["mode"] != "unconfigured"}>
                {cond do
                  !@projection.connections.internet.link ->
                    "Connect the Internet port to your router and check the cable status."

                  !@projection.connections.internet.addressed ->
                    "The cable is connected. Check the gateway's address settings and your router."

                  @projection.connections.internet.health != "online" ->
                    "An address is assigned, but Internet access is not verified. Check your router's Internet connection."

                  true ->
                    "The gateway's Internet check is passing. This does not verify remote equipment access."
                end}
              </.notice>
              <:footer>
                <.button href="/setup" variant="secondary" icon="arrow">Change connections</.button>
              </:footer>
            </.panel>
            <.panel title="Mobile Internet & automatic backup" icon="internet">
              <:meta>
                <.status>Unavailable</.status>
              </:meta>
              <p class="ui-muted">
                Mobile connectivity and failover are not configured by this build. USB is a setup connection, not an Internet backup.
              </p>
            </.panel>
          </div>
          <aside>
            <.live_component
              module={NervesGateWeb.ConnectionPanel}
              id="internet-connections"
              kind={:ports}
            />
          </aside>
        </div>
      <% :remote -> %>
        <.page_header
          eyebrow="Private network"
          title="Remote access"
          description="Access to the equipment you choose. Not public exposure."
        />
        <.panel
          title="Private access, not public exposure"
          description="The next part of your gateway's setup"
          icon="shield"
        >
          <:meta>
            <.status>Setup unavailable</.status>
          </:meta>
          <p class="ui-prose">
            Remote access will use Tailscale. This build does not inspect existing enrollment or route permissions, and local setup alone does not grant equipment access.
          </p>
          <div class="ui-roadmap">
            <div>
              <span>01</span><div>
                <h3>Join your private network</h3><p>
                  Enroll the gateway in Tailscale under your account.
                </p>
              </div>
            </div>
            <div>
              <span>02</span><div>
                <h3>Choose permitted equipment</h3><p>
                  Allow only the networks and access rules you need.
                </p>
              </div>
            </div>
            <div>
              <span>03</span><div>
                <h3>Verify from your remote computer</h3><p>
                  Check the equipment itself, not just the VPN connection.
                </p>
              </div>
            </div>
          </div>
          <:footer>
            <span class="ui-help">Remote access is not reported as ready until it can actually be verified.</span>
          </:footer>
        </.panel>
      <% :settings -> %>
        <.page_header
          eyebrow="Gateway"
          title="Settings"
          description="Local access, firmware information and technical details."
        />
        <div class="ui-stack">
          <.panel
            title="Setup & recovery"
            icon="usb"
            description="Temporary network access and USB recovery."
          >
            <div class="ui-settings-list">
              <.setting_row
                label="Web setup"
                description="Firmware listens on every IPv4 interface at port 4000. Development preview stays on this computer."
              >
                <.status tone="warning">Temporary access</.status>
              </.setting_row>
              <.setting_row
                label="Ethernet & VPN web access"
                description="Available at reachable gateway addresses; VPN enrollment is still separate."
              >
                Enabled on firmware
              </.setting_row>
              <.setting_row
                label="Owner account"
                description="Anyone who can reach this page can change settings. Use only on trusted networks."
              >
                <.status>Not available yet</.status>
              </.setting_row>
            </div>
            <:footer>
              <.button href="/setup" variant="secondary" icon="arrow">Open guided setup</.button>
            </:footer>
          </.panel>
          <.panel
            title="Firmware & diagnostics"
            icon="settings"
            description="Details for maintenance and troubleshooting."
          >
            <div class="ui-settings-list">
              <.setting_row label="Firmware version">
                <code>{@projection.system.firmware}</code>
              </.setting_row>
              <.setting_row label="Platform"><code>{@projection.system.target}</code></.setting_row>
              <.setting_row label="Browser updates & log downloads">
                <.status>Not available yet</.status>
              </.setting_row>
            </div>
            <.notice :if={@projection.network.error} tone="warning">
              {@projection.network.error.message} <code>({@projection.network.error.code})</code>
            </.notice>
            <details class="ui-details">
              <summary>Connection diagnostics</summary><pre>{inspect(@projection.network.observed, pretty: true)}</pre>
            </details>
          </.panel>
        </div>
    <% end %>
    """
  end

  defp arrangement(%{"mode" => "ethernet"}), do: "Separate networks"
  defp arrangement(%{"mode" => "shared"}), do: "One shared network"
  defp arrangement(_), do: "Not assigned"

  defp equipment_address(%{"equipment" => %{"ip_method" => "dhcp"}}),
    do: "Assigned by the existing router"

  defp equipment_address(%{"equipment" => address}), do: address["static_ip"]
  defp equipment_address(_), do: "Not assigned"
end
