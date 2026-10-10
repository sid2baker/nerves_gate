defmodule NervesGateWeb.SetupLive do
  use Phoenix.LiveView
  alias NervesGate.{Config, Device}
  import NervesGateWeb.NetworkStatus, only: [port_label: 1]
  import NervesGateWeb.CoreComponents

  def mount(_, _, socket) do
    subscribe(socket, Device.topic(), &__MODULE__.handle_device/2)
    if connected?(socket), do: Process.send_after(self(), :tick, 1_000)
    projection = Device.projection()
    network = projection.network
    settings = if network.pending, do: network.pending.network, else: network.desired

    {:ok,
     assign(socket,
       projection: projection,
       form: to_form(form_settings(settings), as: :network),
       step: :welcome,
       message: nil,
       now: System.system_time(:millisecond)
     )}
  end

  def handle_event("begin", _, socket),
    do: {:noreply, assign(socket, step: :connections, message: nil)}

  def handle_event("change", %{"network" => params}, socket) do
    params =
      if params["mode"] == "ethernet",
        do: Map.merge(params, %{"ip_method" => "static", "gateway" => nil}),
        else: params

    {:noreply, assign(socket, form: to_form(params, as: :network), message: nil)}
  end

  def handle_event("review", %{"network" => params}, socket) do
    case Device.dispatch("network.validate", %{"network" => network_settings(params)}) do
      {:ok, %{result: %{network: network}, projection: projection}} ->
        {:noreply,
         assign(socket,
           projection: projection,
           form: to_form(form_settings(network), as: :network),
           step: :review,
           message: nil
         )}

      {:error, %{error: error, projection: projection}} ->
        {:noreply, assign(socket, projection: projection, message: error.message)}
    end
  end

  def handle_event("apply", %{"revision" => revision}, %{assigns: %{step: :review}} = socket) do
    result =
      Device.dispatch(
        "network.propose",
        %{"network" => network_settings(socket.assigns.form.params)},
        expected_revision: revision
      )

    command_reply(socket, result, [])
  end

  def handle_event("apply", _, socket),
    do: {:noreply, assign(socket, message: "Review your settings before applying them.")}

  def handle_event("confirm", params, socket) do
    command_reply(socket, Device.dispatch("network.confirm", Map.take(params, ["trial_id"])),
      step: :done
    )
  end

  def handle_event("cancel", params, socket) do
    command_reply(socket, Device.dispatch("network.cancel", Map.take(params, ["trial_id"])),
      step: :connections,
      message: "Restoring previous settings."
    )
  end

  @doc false
  def handle_device({:device, _projection}, socket),
    do: assign(socket, projection: Device.projection())

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, assign(socket, now: System.system_time(:millisecond))}
  end

  def render(assigns) do
    assigns =
      assign(
        assigns,
        :progress,
        cond do
          assigns.step == :done -> 4
          assigns.projection.network.pending -> 3
          assigns.step == :review -> 2
          true -> 1
        end
      )

    ~H"""
    <.page_header
      eyebrow="Guided setup"
      title="A place for every connection"
      description="Choose how the gateway reaches the Internet and where your equipment connects."
    />
    <div class="ui-disconnected">
      <.notice tone="warning" role="alert">
        Connection lost. Keep USB connected and reload this page. Unconfirmed changes still roll back automatically.
      </.notice>
    </div>
    <.stepper current={@progress} labels={["Connections", "Review", "Save"]} />
    <.notice :if={@message} tone="warning" role="alert">{@message}</.notice>
    <.notice :if={@projection.network.error} tone="warning" role="alert">
      {@projection.network.error.message}
    </.notice>
    <div class="ui-content-grid">
      <div class="ui-stack">
        <%= cond do %>
          <% !@projection.network.available -> %>
            <.panel title="Connection settings are restarting" icon="clock">
              <p>Wait for the gateway to reconnect. Unconfirmed changes still roll back.</p>
            </.panel>
          <% @projection.network.desired == nil -> %>
            <.panel title="Saved settings need attention" icon="info">
              <p>
                Your saved file could not be read and has not been overwritten. Use recovery SSH or serial to inspect /data/nerves_gate.json.
              </p>
            </.panel>
          <% @projection.network.pending != nil -> %>
            <.panel
              title="Check the port assignments"
              description="The new connections are being tried. Nothing is saved yet."
              icon="clock"
            >
              <div class="ui-trial-clock">
                <span role="timer">{max(
                  0,
                  div(@projection.network.pending.expires_at - @now + 999, 1000)
                )}<small>seconds</small></span><div>
                  <strong>Automatic restore is on</strong><p>
                    Keep these settings, or let the gateway return to the previous connections.
                  </p>
                </div>
              </div>
              <p class="ui-help">
                USB setup stays separate. Saving does not verify Internet or remote equipment access.
              </p>
              <.notice :if={!@projection.actions["network.confirm"].enabled} tone="warning">
                {@projection.actions["network.confirm"].reason.message}
              </.notice>
              <:footer>
                <div class="ui-actions">
                  <.button
                    id="confirm-settings"
                    phx-click="confirm"
                    phx-value-trial_id={@projection.network.pending.id}
                    disabled={!@projection.actions["network.confirm"].enabled}
                    icon="check"
                  >Keep these settings</.button>
                  <.button
                    variant="secondary"
                    phx-click="cancel"
                    phx-value-trial_id={@projection.network.pending.id}
                    disabled={!@projection.actions["network.cancel"].enabled}
                  >Restore previous settings</.button>
                </div>
              </:footer>
            </.panel>
          <% @step == :welcome -> %>
            <.panel
              title="Start with the connections"
              description="Two Ethernet ports. One independent setup connection."
              icon="network"
            >
              <div
                class="ui-setup-diagram"
                role="img"
                aria-label="USB for setup; Ethernet for Internet and equipment"
              >
                <div><.icon name="internet" /><strong>Internet</strong><span>Your router</span></div><span
                  class="ui-diagram-line"
                  aria-hidden="true"
                ></span><div class="ui-diagram-gateway">
                  <.icon name="port" /><strong>Gateway</strong><span>USB setup</span>
                </div><span class="ui-diagram-line" aria-hidden="true"></span><div>
                  <.icon name="equipment" /><strong>Equipment</strong><span>Your network</span>
                </div>
              </div>
              <p>
                Choose a connection for each side, then give the gateway an unused address in your equipment network. Your equipment keeps its existing addresses.
              </p>
              <.notice icon="usb" title="Keep the USB cable connected">
                Setup works without Internet and uses neither Ethernet port. USB does not automatically share your laptop's Internet.
              </.notice>
              <p class="ui-help">
                Mobile Internet, automatic backup and remote-access enrollment are not available in this build.
              </p>
              <:footer><.button phx-click="begin" icon="arrow">Set up connections</.button></:footer>
            </.panel>
          <% @step == :connections -> %>
            <.form
              for={@form}
              id="network-form"
              phx-change="change"
              phx-submit="review"
              class="ui-stack"
            >
              <.panel
                title="Internet connection"
                description="How should the two Ethernet ports work together?"
                icon="internet"
              >
                <.choice_group field={@form[:mode]} label="Connection arrangement">
                  <:option
                    value="ethernet"
                    title="Separate networks"
                    description="One port for your router. The other for equipment."
                    icon="network"
                  />
                  <:option
                    value="shared"
                    title="One shared network"
                    description="Router and equipment already belong to the same network."
                    icon="port"
                  />
                </.choice_group>
                <.choice_group
                  :if={@form.params["mode"] == "ethernet"}
                  field={@form[:internet_port]}
                  label="Which port connects to your Internet router?"
                  description="The other port is automatically reserved for equipment."
                >
                  <:option
                    value="eth0"
                    title="Port 1 → Internet"
                    description="Port 2 → Equipment"
                    icon="port"
                  />
                  <:option
                    value="eth1"
                    title="Port 2 → Internet"
                    description="Port 1 → Equipment"
                    icon="port"
                  />
                </.choice_group>
                <p :if={@form.params["mode"] == "ethernet"} class="ui-help">
                  The Internet router assigns its address automatically (DHCP).
                </p>
                <.notice
                  :if={@form.params["mode"] == "shared"}
                  tone="warning"
                  title="Both ports will be joined"
                >
                  This explicitly joins both Ethernet ports. Use only for one trusted network, never two different networks.
                </.notice>
              </.panel>
              <.panel
                title="Equipment connection"
                description="An address for the gateway, not a change to your equipment."
                icon="equipment"
              >
                <:meta :if={@form.params["mode"] == "ethernet"}>
                  <span class="ui-port-tag">{port_label(
                    if @form.params["internet_port"] == "eth0", do: "eth1", else: "eth0"
                  )}</span>
                </:meta>
                <.choice_group
                  :if={@form.params["mode"] == "shared"}
                  field={@form[:ip_method]}
                  label="Gateway address assignment"
                >
                  <:option
                    value="static"
                    title="Choose an address"
                    description="Use an unused address in the existing subnet."
                    icon="settings"
                  />
                  <:option
                    value="dhcp"
                    title="Automatic"
                    description="Let the existing router assign an address."
                    icon="network"
                  />
                </.choice_group>
                <input
                  :if={@form.params["mode"] == "ethernet"}
                  type="hidden"
                  name="network[ip_method]"
                  value="static"
                />
                <div :if={@form.params["ip_method"] == "static"} class="ui-field-grid">
                  <.field
                    field={@form[:static_ip]}
                    label="Gateway's equipment-side address"
                    help="An unused address in your equipment's subnet."
                    placeholder="192.168.10.2"
                    inputmode="decimal"
                    autocomplete="off"
                    required
                  />
                  <.field
                    field={@form[:subnet_mask]}
                    label="Equipment subnet mask"
                    help="Use the mask your equipment network uses."
                    placeholder="255.255.255.0"
                    inputmode="decimal"
                    autocomplete="off"
                    required
                  />
                  <.field
                    :if={@form.params["mode"] == "shared"}
                    field={@form[:gateway]}
                    label="Router address (optional)"
                    inputmode="decimal"
                    autocomplete="off"
                  />
                </div>
                <p class="ui-help">
                  Not sure which address is free? Ask your network administrator. Automatic discovery is not available yet; no Ethernet DHCP server is started.
                </p>
                <:footer>
                  <div class="ui-actions ui-actions--between">
                    <span class="ui-help">Nothing changes until you review.</span><.button
                      type="submit"
                      icon="arrow"
                    >Review settings</.button>
                  </div>
                </:footer>
              </.panel>
            </.form>
          <% @step == :review -> %>
            <.panel
              title="Review before changing anything"
              description="Your connection plan"
              icon="network"
            >
              <div class="ui-settings-list">
                <.setting_row
                  :if={@form.params["mode"] == "ethernet"}
                  label="Internet"
                  description="Address assigned by your router"
                >
                  {port_label(@form.params["internet_port"])}
                </.setting_row>
                <.setting_row :if={@form.params["mode"] == "ethernet"} label="Equipment">
                  {port_label(if @form.params["internet_port"] == "eth0", do: "eth1", else: "eth0")}
                </.setting_row>
                <.setting_row label="Arrangement">
                  {if @form.params["mode"] == "shared",
                    do: "One shared network",
                    else: "Separate networks"}
                </.setting_row>
                <.setting_row label="Gateway's equipment-side address">
                  <code>{if @form.params["ip_method"] == "dhcp",
                    do: "Automatic (DHCP)",
                    else: @form.params["static_ip"]}</code>
                </.setting_row>
                <.setting_row :if={@form.params["ip_method"] == "static"} label="Subnet mask">
                  <code>{@form.params["subnet_mask"]}</code>
                </.setting_row>
                <.setting_row
                  :if={@form.params["mode"] == "shared" && @form.params["ip_method"] == "static"}
                  label="Router address"
                >
                  <code>{@form.params["gateway"] || "Not set"}</code>
                </.setting_row>
              </div>
              <.notice :if={@form.params["mode"] == "shared"} tone="warning">
                Both ports will be joined into one shared network.
              </.notice>
              <.notice icon="clock" title="A 60-second safety check">
                Ethernet traffic may pause. USB setup is unchanged. Confirm within 60 seconds, or the previous settings return automatically.
              </.notice>
              <.notice :if={!@projection.actions["network.propose"].enabled} tone="warning">
                {@projection.actions["network.propose"].reason.message}
              </.notice>
              <:footer>
                <div class="ui-actions">
                  <.button
                    id="apply-settings"
                    phx-click="apply"
                    phx-value-revision={@projection.revision}
                    disabled={!@projection.actions["network.propose"].enabled}
                  >Try for 60 seconds</.button><.button phx-click="begin" variant="secondary">Edit settings</.button>
                </div>
              </:footer>
            </.panel>
          <% @step == :done -> %>
            <.panel
              title="Connection settings saved"
              description="Your local connection plan is in place."
              icon="check"
            >
              <p>Your port assignments and local address will survive a restart.</p>
              <.notice title="Next: private remote access" icon="shield">
                Remote access is not verified. This build cannot check enrollment, network permissions or reachability from your remote computer.
              </.notice>
              <:footer><.button href="/" icon="arrow">Open overview</.button></:footer>
            </.panel>
        <% end %>
      </div>
      <aside class="ui-stack ui-context-rail" aria-label="Connection context">
        <.live_component module={NervesGateWeb.ConnectionPanel} id="setup-connections" kind={:ports} />
        <div class="ui-rail-note">
          <.icon name="usb" /><div>
            <strong>USB stays independent</strong><p>
              Change Ethernet connections without moving your setup cable.
            </p>
          </div>
        </div>
      </aside>
    </div>
    """
  end

  defp form_settings(settings) do
    address =
      (settings && settings["equipment"]) ||
        %{
          "ip_method" => "static",
          "static_ip" => "",
          "subnet_mask" => "255.255.255.0",
          "gateway" => nil
        }

    Map.merge(address, %{
      "mode" => if(settings && settings["mode"] == "shared", do: "shared", else: "ethernet"),
      "internet_port" => (settings && settings["internet_port"]) || "eth0"
    })
  end

  defp network_settings(params) do
    address = Map.take(params, Map.keys(Config.address_defaults()))

    case params["mode"] do
      "shared" ->
        %{"mode" => "shared", "equipment" => address}

      "ethernet" ->
        %{
          "mode" => "ethernet",
          "internet_port" => params["internet_port"],
          "equipment" => address
        }

      _ ->
        %{}
    end
  end

  defp command_reply(socket, {:ok, %{projection: projection}}, assigns),
    do: {:noreply, socket |> assign(projection: projection, message: nil) |> assign(assigns)}

  defp command_reply(socket, {:error, %{error: error, projection: projection}}, _),
    do: {:noreply, assign(socket, projection: projection, message: error.message)}
end
