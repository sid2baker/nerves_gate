defmodule NervesGateWeb.NetworkEditor do
  @moduledoc "Separate drafts sharing the device-owned network trial workflow."
  use Phoenix.LiveComponent
  alias NervesGate.Network
  alias NervesGateWeb.{Backend, NetworkForm}
  import NervesGateWeb.NetworkStatus, only: [port_label: 1]
  import NervesGateWeb.CoreComponents

  def update(%{tick: true}, socket) do
    {:ok, socket |> assign(ticking: false, now: System.system_time(:millisecond)) |> tick()}
  end

  def update(assigns, %{assigns: %{base: _}} = socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:projection]))
      |> assign(:now, System.system_time(:millisecond))

    {:ok, socket |> refresh_observations(assigns.projection) |> tick()}
  end

  def update(assigns, socket) do
    projection = assigns.projection

    socket =
      socket
      |> assign(assigns)
      |> assign(
        form:
          to_form(NetworkForm.from_settings(projection.network.desired, assigns.editor),
            as: :network
          ),
        base: projection.network.desired,
        dirty: false,
        editing_internet: projection.connections.suggested_internet_port == nil,
        own_save: false,
        saving_network: nil,
        initial: not projection.network.setup_completed,
        message: nil,
        ticking: false,
        now: System.system_time(:millisecond)
      )

    {:ok, tick(socket)}
  end

  defp tick(socket) do
    if connected?(socket) and socket.assigns.projection.network.pending != nil and
         not socket.assigns.ticking do
      send_update_after(__MODULE__, %{id: socket.assigns.id, tick: true}, 1_000)
      assign(socket, :ticking, true)
    else
      socket
    end
  end

  def handle_event("edit-internet", _, socket),
    do: {:noreply, assign(socket, editing_internet: not socket.assigns.editing_internet)}

  def handle_event("change", %{"network" => params}, socket),
    do: {:noreply, assign(socket, form: draft(socket, params), dirty: true, message: nil)}

  def handle_event("reload", _, socket),
    do:
      {:noreply,
       socket |> assign(dirty: false, message: nil) |> refresh(socket.assigns.projection)}

  def handle_event("save", %{"network" => params}, socket) do
    socket = assign(socket, form: draft(socket, params))

    case NetworkForm.to_network(
           socket.assigns.form.params,
           socket.assigns.projection.connections.ports,
           socket.assigns.base,
           socket.assigns.editor
         ) do
      {:ok, network} ->
        result =
          Backend.network_propose(network,
            access: socket.assigns.access,
            expected: socket.assigns.base
          )

        reply(assign(socket, own_save: true, saving_network: network), result)

      {:error, message} ->
        {:noreply, assign(socket, dirty: true, message: message)}
    end
  end

  def handle_event("confirm", params, socket),
    do: reply(socket, Backend.network_confirm(params["trial_id"]))

  def handle_event("cancel", params, socket),
    do: reply(assign(socket, own_save: false), Backend.network_cancel(params["trial_id"]))

  @doc false
  def refresh_observations(socket, %{backend: %{available: false}} = projection),
    do: assign(socket, :projection, projection)

  def refresh_observations(socket, projection), do: refresh(socket, projection)

  defp draft(socket, params) do
    previous = socket.assigns.form.params

    previous
    |> Map.merge(Map.take(params, Map.keys(previous)))
    |> NetworkForm.defaults_for_change(
      previous,
      socket.assigns.editor,
      socket.assigns.projection.network.observed
    )
    |> to_form(as: :network)
  end

  defp refresh(socket, projection) do
    previous = socket.assigns.projection.network
    network = projection.network
    socket = assign(socket, projection: projection, initial: not network.setup_completed)

    cond do
      saved?(socket.assigns, network, previous) ->
        saved(socket, network, previous)

      socket.assigns.own_save and previous.pending != nil and network.pending == nil ->
        assign(socket, own_save: false)

      not socket.assigns.dirty and network.desired != socket.assigns.base ->
        assign(socket,
          base: network.desired,
          form:
            to_form(NetworkForm.from_settings(network.desired, socket.assigns.editor),
              as: :network
            )
        )

      true ->
        socket
    end
  end

  defp saved?(assigns, network, previous) do
    assigns.own_save and network.pending == nil and network.setup_completed and
      network.error == nil and network.desired == assigns.saving_network and
      (previous.pending != nil or previous.desired != network.desired or
         previous.setup_completed != network.setup_completed)
  end

  defp saved(socket, network, previous) do
    socket =
      assign(socket,
        own_save: false,
        dirty: false,
        initial: false,
        base: network.desired,
        form:
          to_form(NetworkForm.from_settings(network.desired, socket.assigns.editor), as: :network),
        message: "Settings saved."
      )

    if socket.assigns.editor == :internet and not previous.setup_completed,
      do: push_navigate(socket, to: "/"),
      else: socket
  end

  defp reply(socket, {:ok, _trial_id}), do: reply(socket, :ok)
  defp reply(socket, :ok), do: {:noreply, socket}

  defp reply(socket, {:error, error}),
    do: {:noreply, assign(socket, own_save: false, dirty: true, message: error.message)}

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
        pending: assigns.projection.network.pending,
        equipment_reason:
          NetworkForm.equipment_reason(assigns.projection.network.desired, assigns.editor)
      )

    ~H"""
    <div id={@id} class="ui-stack">
      <p :if={@initial and @editor == :internet} class="ui-help">
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
                  <strong>Previous settings return automatically</strong>
                  <p>Keep the changes now, or let the timer run out.</p>
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
                  phx-target={@myself}
                  phx-click="confirm"
                  phx-value-trial_id={@pending.id}
                  disabled={!@projection.actions["network.confirm"].enabled}
                >Keep changes</.button>
                <.button
                  variant="secondary"
                  phx-target={@myself}
                  phx-click="cancel"
                  phx-value-trial_id={@pending.id}
                >Restore previous settings</.button>
              </div>
            <% end %>
          </.panel>
        <% @equipment_reason != nil -> %>
          <.notice tone="warning">{@equipment_reason}</.notice>
        <% true -> %>
          <.notice :if={@stale} tone="warning">
            Settings changed in another session. Your draft has not been applied.
            <.button variant="secondary" phx-target={@myself} phx-click="reload">Reload saved settings</.button>
          </.notice>
          <.form
            for={@form}
            id={
              case @editor do
                :internet -> "network-form"
                :ports -> "lan-ports-form"
                _ -> "equipment-network-form"
              end
            }
            phx-target={@myself}
            phx-change="change"
            phx-submit="save"
            class="ui-stack"
          >
            <%= cond do %>
              <% @editor == :ports -> %>
                <.panel title="LAN ports" icon="port">
                  <.choice_group field={@form[:mode]} label="Port arrangement">
                    <:option
                      value="ports"
                      title="Separate"
                      description="Use each port independently."
                    />
                    <:option
                      value="shared"
                      title="Joined"
                      description="Use both ports as one network."
                    />
                  </.choice_group>
                  <%= if @form.params["mode"] == "shared" do %>
                    <.notice tone="warning">
                      Only join ports on the same trusted network. Separate port assignments are replaced.
                    </.notice>
                    <.address_fields form={@form} prefix="shared" />
                  <% else %>
                    <.notice :if={@base["mode"] == "shared"} tone="warning">
                      Separating removes the shared address and leaves both ports unassigned.
                    </.notice>
                  <% end %>
                </.panel>
              <% @editor == :internet -> %>
                <.panel title="Internet source" icon="internet">
                  <.choice_group field={@form[:internet_mode]} label="Connect using">
                    <:option
                      value="ethernet"
                      title="Ethernet"
                      description="Use a LAN port for Internet."
                    />
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
                <%= if @base["mode"] != "shared" do %>
                  <.panel
                    :if={@form.params["internet_mode"] != "cellular"}
                    title="Ethernet Internet"
                    icon="internet"
                  >
                    <p id="internet-summary">
                      <strong>{if @internet, do: port_label(@internet) <> " · "}{@internet_status}</strong>
                    </p>
                    <p :if={!@internet} class="ui-help">
                      You can finish offline and add Internet later.
                    </p>
                    <.button
                      variant="secondary"
                      phx-target={@myself}
                      phx-click="edit-internet"
                      aria-expanded={to_string(@editing_internet)}
                      aria-controls="internet-options"
                    >{if @editing_internet,
                      do: "Hide Internet settings",
                      else: "Change Internet connection"}</.button>
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
                          title="LAN 1"
                          description={internet_status("eth0", @projection.connections.ports)}
                        />
                        <:option
                          value="eth1"
                          title="LAN 2"
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
                <% end %>
              <% true -> %>
                <.panel title="Equipment network" icon="equipment">
                  <.choice_group field={@form[:enabled]} label="Use this LAN port">
                    <:option
                      value="true"
                      title="Equipment"
                      description="Assign an address on your equipment’s network."
                    />
                    <:option
                      value="false"
                      title="Not configured"
                      description="Leave this port unused."
                    />
                  </.choice_group>
                  <div :if={@form.params["enabled"] == "true"} class="ui-field-grid">
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
                    Check the address before saving. Equipment keeps its own addresses; Internet settings are preserved.
                  </p>
                </.panel>
            <% end %>
            <.notice :if={@initial and @usb} icon="usb">
              You’re connected through USB. Settings save directly; USB stays available.
            </.notice>
            <.notice :if={!@projection.actions["network.propose"].enabled} tone="warning">
              {@projection.actions["network.propose"].reason.message}
            </.notice>
            <div class="ui-actions">
              <.button
                id="apply-settings"
                type="submit"
                disabled={
                  @stale or !@projection.actions["network.propose"].enabled or
                    (@editor == :internet and @form.params["internet_mode"] != "ethernet" and
                       !@projection.capabilities.mobile)
                }
                phx-disable-with="Applying…"
              >{if @initial and @editor == :internet, do: "Finish setup", else: "Apply changes"}</.button>
              <.button :if={@initial and @editor == :internet} href="/" variant="quiet">Do this later</.button>
            </div>
          </.form>
      <% end %>
    </div>
    """
  end

  attr(:form, :any, required: true)
  attr(:prefix, :string, required: true)

  defp address_fields(assigns) do
    assigns =
      assign(
        assigns,
        :fields,
        Map.new(~w(method ip mask gateway dns), &{&1, assigns.form[assigns.prefix <> "_" <> &1]})
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
