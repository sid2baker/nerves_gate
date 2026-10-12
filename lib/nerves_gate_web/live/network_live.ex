defmodule NervesGateWeb.NetworkLive do
  use Phoenix.LiveView
  alias NervesGate.Network
  alias NervesGateWeb.NetworkForm
  import NervesGateWeb.NetworkStatus, only: [port_label: 1]
  import NervesGateWeb.CoreComponents
  import NervesGateWeb.Layouts, only: [settings_nav: 1]

  def mount(_, session, socket) do
    socket = NervesGateWeb.Observations.subscribe(socket, &__MODULE__.refresh_observations/1)
    if connected?(socket), do: Process.send_after(self(), :tick, 1_000)
    projection = NervesGate.status()
    peer = get_connect_info(socket, :peer_data)

    socket =
      assign(socket,
        projection: projection,
        access: %{local: session["local_address"], peer: peer && peer.address},
        form: to_form(NetworkForm.from_settings(projection.network.desired), as: :network),
        base: projection.network.desired,
        dirty: false,
        editing_internet: projection.connections.suggested_internet_port == nil,
        own_save: false,
        saving_network: nil,
        initial: not projection.network.setup_completed,
        message: nil,
        now: System.system_time(:millisecond)
      )

    {:ok, socket}
  end

  def handle_event("edit-internet", _, socket) do
    {:noreply, assign(socket, editing_internet: not socket.assigns.editing_internet)}
  end

  def handle_event("change", %{"network" => params}, socket) do
    {:noreply, assign(socket, form: draft(socket, params), dirty: true, message: nil)}
  end

  def handle_event("add-equipment", _, socket) do
    internet =
      NetworkForm.internet_port(
        socket.assigns.form.params,
        socket.assigns.projection.connections.ports
      )

    port = if internet == "eth1", do: "eth0", else: "eth1"
    {:noreply, assign(socket, form: draft(socket, %{"equipment_port" => port}), dirty: true)}
  end

  def handle_event("remove-equipment", _, socket),
    do: {:noreply, assign(socket, form: draft(socket, %{"equipment_port" => ""}), dirty: true)}

  def handle_event("reload", _, socket) do
    {:noreply, socket |> assign(dirty: false, message: nil) |> refresh(NervesGate.status())}
  end

  def handle_event("save", %{"network" => params}, socket) do
    projection = NervesGate.status()
    socket = assign(socket, form: draft(socket, params))

    if socket.assigns.base != projection.network.desired do
      {:noreply,
       assign(socket,
         projection: projection,
         dirty: true,
         message: "Settings changed in another session. Reload saved settings before editing."
       )}
    else
      case NetworkForm.to_network(socket.assigns.form.params, projection.connections.ports) do
        {:ok, network} ->
          result =
            NervesGate.network_propose(network,
              access: socket.assigns.access
            )

          reply(assign(socket, own_save: true, saving_network: network), result)

        {:error, message} ->
          {:noreply, assign(socket, message: message)}
      end
    end
  end

  def handle_event("confirm", params, socket),
    do:
      reply(
        assign(socket,
          own_save: true,
          saving_network:
            socket.assigns.projection.network.pending &&
              socket.assigns.projection.network.pending.network
        ),
        NervesGate.network_confirm(params["trial_id"])
      )

  def handle_event("cancel", params, socket),
    do:
      reply(
        assign(socket, own_save: false),
        NervesGate.network_cancel(params["trial_id"])
      )

  @doc false
  def refresh_observations(socket) do
    refresh(socket, NervesGate.status())
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, assign(socket, now: System.system_time(:millisecond))}
  end

  defp draft(socket, params) do
    previous = socket.assigns.form.params
    merged = Map.merge(previous, Map.take(params, Map.keys(previous)))

    merged =
      Enum.reduce(["internet", "shared", "equipment"], merged, fn prefix, acc ->
        added =
          prefix == "equipment" and previous["equipment_port"] == "" and
            acc["equipment_port"] != ""

        manual =
          previous["#{prefix}_method"] != "static" and acc["#{prefix}_method"] == "static"

        if added or manual do
          NetworkForm.static_defaults(acc, prefix, socket.assigns.projection.network.observed)
        else
          acc
        end
      end)

    to_form(merged, as: :network)
  end

  defp refresh(socket, projection) do
    previous = socket.assigns.projection.network
    network = projection.network
    socket = assign(socket, projection: projection, initial: not network.setup_completed)

    cond do
      saved?(socket.assigns, network) ->
        saved(socket, network, previous)

      socket.assigns.own_save and network.pending == nil ->
        assign(socket, own_save: false)

      not socket.assigns.dirty and network.desired != socket.assigns.base ->
        assign(socket,
          base: network.desired,
          form: to_form(NetworkForm.from_settings(network.desired), as: :network)
        )

      true ->
        socket
    end
  end

  defp saved?(assigns, network) do
    assigns.own_save and network.pending == nil and network.setup_completed and
      network.error == nil and
      network.desired == assigns.saving_network
  end

  defp saved(socket, network, previous) do
    socket =
      assign(socket,
        own_save: false,
        dirty: false,
        initial: false,
        base: network.desired,
        form: to_form(NetworkForm.from_settings(network.desired), as: :network),
        message: "Settings saved."
      )

    if previous.setup_completed do
      socket
    else
      push_navigate(socket, to: "/")
    end
  end

  defp reply(socket, {:ok, _trial_id}) do
    reply(socket, :ok)
  end

  defp reply(socket, :ok) do
    {:noreply, refresh(socket, NervesGate.status())}
  end

  defp reply(socket, {:error, error}) do
    {:noreply,
     assign(socket, projection: NervesGate.status(), own_save: false, message: error.message)}
  end

  def render(assigns) do
    internet =
      NetworkForm.internet_port(assigns.form.params, assigns.projection.connections.ports)

    assigns =
      assign(assigns,
        usb: Network.Access.usb?(assigns.projection.network.observed, assigns.access),
        internet: internet,
        internet_status:
          if(assigns.form.params["internet_port"] == "",
            do: "Not configured",
            else: internet_status(internet, assigns.projection.connections.ports)
          ),
        stale: assigns.base != assigns.projection.network.desired,
        pending: assigns.projection.network.pending
      )

    ~H"""
    <.page_header
      eyebrow="Settings"
      title="Network"
      description="Choose your Internet source and equipment port. USB stays independent for recovery."
    />
    <.settings_nav current={:network} />
    <p :if={@initial} class="ui-help">
      First setup · Connect what you need. Everything else can wait.
    </p>
    <.notice :if={@message} role="status">{@message}</.notice>
    <.notice :if={@projection.network.error} tone="warning" role="alert">
      {@projection.network.error.message}
    </.notice>
    <%= cond do %>
      <% !@projection.network.available or @projection.network.desired == nil -> %>
        <.notice tone="warning">
          Saved settings are unavailable. They have not been overwritten. Reconnect, or inspect VintageNet's saved settings using recovery SSH.
        </.notice>
      <% @pending != nil -> %>
        <.panel
          title={if @pending.auto_save, do: "Saving settings…", else: "Keep these changes?"}
          icon="clock"
        >
          <%= if @pending.auto_save do %>
            <p>Applying your connections. USB stays available. No confirmation is needed.</p>
          <% else %>
            <div class="ui-trial-clock">
              <span role="timer">{max(0, div(@pending.expires_at - @now + 999, 1000))}<small>seconds</small></span>
              <div>
                <strong>Previous settings return automatically</strong><p>
                  Keep the changes now, or let the timer run out.
                </p>
              </div>
            </div>
            <p class="ui-help">
              Internet access is not required. Check that your local settings are correct.
            </p>
            <.notice :if={!@projection.actions["network.confirm"].enabled} tone="warning">
              {@projection.actions["network.confirm"].reason.message}
            </.notice>
            <div class="ui-actions">
              <.button
                id="confirm-settings"
                phx-click="confirm"
                phx-value-trial_id={@pending.id}
                disabled={!@projection.actions["network.confirm"].enabled}
              >Keep changes</.button>
              <.button variant="secondary" phx-click="cancel" phx-value-trial_id={@pending.id}>Restore previous settings</.button>
            </div>
          <% end %>
        </.panel>
      <% true -> %>
        <.notice :if={@stale} tone="warning">
          Settings changed in another session. Your draft has not been applied.
          <.button variant="secondary" phx-click="reload">Reload saved settings</.button>
        </.notice>
        <.form for={@form} id="network-form" phx-change="change" phx-submit="save" class="ui-stack">
          <.panel title="Internet source" icon="internet">
            <.choice_group field={@form[:internet_mode]} label="Connect using">
              <:option value="ethernet" title="Ethernet" description="Use a LAN port for Internet." />
              <:option
                value="cellular"
                title="4G modem"
                description="Use cellular only; keep equipment separate."
              />
              <:option
                value="backup"
                title="Ethernet with 4G backup"
                description="Prefer Ethernet; use 4G when Ethernet has no Internet."
              />
            </.choice_group>
            <.notice :if={!@projection.capabilities.mobile}>
              This firmware has no qualified cellular setup. Identify the modem and configure its driver and dedicated interface before enabling 4G.
            </.notice>
            <div :if={@form.params["internet_mode"] in ["cellular", "backup"]}>
              <.field
                field={@form[:cellular_apn]}
                label="Cellular APN"
                help="Use the APN supplied by your mobile operator."
                required
                autocomplete="off"
              />
              <p class="ui-help">
                SIM must already be unlocked. PIN and account-password setup are not supported yet.
              </p>
              <p :if={@form.params["internet_mode"] == "backup"} class="ui-help">
                4G stays connected on standby. Connectivity checks can use mobile data. Existing connections may briefly interrupt during a switch.
              </p>
            </div>
          </.panel>
          <%= if @form.params["mode"] == "ports" do %>
            <.panel
              :if={@form.params["internet_mode"] != "cellular"}
              title="Ethernet Internet"
              icon="internet"
            >
              <p id="internet-summary">
                <strong>{if @internet, do: port_label(@internet) <> " · "}{@internet_status}</strong>
              </p>
              <p :if={!@internet} class="ui-help">You can finish offline and add Internet later.</p>
              <.button
                variant="secondary"
                phx-click="edit-internet"
                aria-expanded={to_string(@editing_internet)}
                aria-controls="internet-options"
              >{if @editing_internet, do: "Hide Internet settings", else: "Change Internet connection"}</.button>
              <div :if={@editing_internet} id="internet-options">
                <.choice_group field={@form[:internet_port]} label="Internet port">
                  <:option
                    :if={@initial}
                    value="auto"
                    title="Automatic"
                    description="Use the detected connection."
                  />
                  <:option
                    value="eth0"
                    title="Port 1"
                    description={internet_status("eth0", @projection.connections.ports)}
                  />
                  <:option
                    value="eth1"
                    title="Port 2"
                    description={internet_status("eth1", @projection.connections.ports)}
                  />
                  <:option value="" title="Not now" />
                </.choice_group>
                <.address_fields
                  :if={@form.params["internet_port"] != ""}
                  form={@form}
                  prefix="internet"
                />
              </div>
            </.panel>
            <.panel title="Equipment" icon="equipment">
              <%= if @form.params["equipment_port"] == "" do %>
                <input type="hidden" name="network[equipment_port]" value="" />
                <p>Not configured. Add your equipment now or later.</p>
                <.button variant="secondary" phx-click="add-equipment">Add equipment</.button>
              <% else %>
                <.choice_group field={@form[:equipment_port]} label="Equipment port">
                  <:option value="eth0" title="Port 1" />
                  <:option value="eth1" title="Port 2" />
                </.choice_group>
                <div class="ui-field-grid">
                  <.field
                    field={@form[:equipment_ip]}
                    label="Gateway address on the equipment network"
                    help="Use an unused address in your equipment’s subnet."
                    placeholder="192.168.10.2"
                    required
                    autocomplete="off"
                  />
                  <.field
                    field={@form[:equipment_mask]}
                    label="Subnet mask"
                    required
                    autocomplete="off"
                  />
                </div>
                <p class="ui-help">
                  Check the suggested address before saving. Your equipment keeps its own addresses.
                </p>
                <.button variant="quiet" phx-click="remove-equipment">Remove equipment connection</.button>
              <% end %>
            </.panel>
          <% else %>
            <.panel title="Shared network" icon="network">
              <.notice tone="warning">
                Both Ethernet ports will be joined. Only use this for one trusted network, never two different networks.
              </.notice>
              <.address_fields form={@form} prefix="shared" />
            </.panel>
          <% end %>
          <details
            id="advanced-network"
            open={@form.params["mode"] == "shared"}
            phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
          >
            <summary>Advanced: shared network</summary>
            <.choice_group field={@form[:mode]} label="Port arrangement">
              <:option
                value="ports"
                title="Separate ports"
                description="Internet and equipment stay separate."
              />
              <:option
                value="shared"
                title="One shared network"
                description="Explicitly join both Ethernet ports."
              />
            </.choice_group>
          </details>
          <.notice :if={@initial and @usb} icon="usb">
            You’re connected through USB. Settings save directly; USB stays available.
          </.notice>
          <p :if={!@initial or !@usb} class="ui-help">
            Network changes have a 60-second undo window. Keep them when ready, or they restore automatically.
          </p>
          <.notice :if={!@projection.actions["network.propose"].enabled} tone="warning">
            {@projection.actions["network.propose"].reason.message}
          </.notice>
          <div class="ui-actions">
            <.button
              id="apply-settings"
              type="submit"
              disabled={
                @stale or !@projection.actions["network.propose"].enabled or
                  (@form.params["internet_mode"] != "ethernet" and !@projection.capabilities.mobile)
              }
              phx-disable-with="Applying…"
            >{if @initial, do: "Finish setup", else: "Apply changes"}</.button>
            <.button :if={@initial} href="/" variant="quiet">Do this later</.button>
          </div>
        </.form>
    <% end %>
    <details
      id="connection-details"
      class="ui-settings-details"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
    >
      <summary>Connection details</summary>
      <.live_component
        module={NervesGateWeb.ConnectionPanel}
        id="network-connections"
        projection={@projection}
      />
      <p class="ui-help">USB stays separate for setup and recovery.</p>
    </details>
    """
  end

  attr(:form, :any, required: true)
  attr(:prefix, :string, required: true)

  defp address_fields(assigns) do
    assigns =
      assign(
        assigns,
        :fields,
        Map.new(~w(method ip mask gateway dns), fn key ->
          {key, assigns.form[assigns.prefix <> "_" <> key]}
        end)
      )

    ~H"""
    <.choice_group field={@fields["method"]} label="Address assignment">
      <:option value="dhcp" title="Automatic (DHCP)" />
      <:option value="static" title="Manual" />
    </.choice_group>
    <p :if={@fields["method"].value == "static"} class="ui-help">
      Check these suggested addresses. Reserve an address on your router before using it manually.
    </p>
    <div :if={@fields["method"].value == "static"} class="ui-field-grid">
      <.field field={@fields["ip"]} label="Gateway address" required autocomplete="off" />
      <.field field={@fields["mask"]} label="Subnet mask" required autocomplete="off" />
      <.field field={@fields["gateway"]} label="Router address (optional)" autocomplete="off" />
      <.field
        field={@fields["dns"]}
        label="DNS servers (optional)"
        help="IPv4 addresses, separated by commas."
        autocomplete="off"
      />
    </div>
    """
  end

  defp internet_status(nil, ports) do
    if Enum.count(ports, &(&1.link and Map.get(&1, :addresses, []) != [])) > 1,
      do: "Choose which connection to use",
      else: "No Internet connection selected"
  end

  defp internet_status(name, ports) do
    case Enum.find(ports, &(&1.name == name)) do
      nil -> "Not installed"
      port -> Network.Discovery.status(port)
    end
  end
end
