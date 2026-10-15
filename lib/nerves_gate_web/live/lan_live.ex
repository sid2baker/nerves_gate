defmodule NervesGateWeb.LanLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents

  import NervesGateWeb.NetworkStatus,
    only: [lan_ports: 1, equipment_interface: 1, equipment_status: 1, port_label: 1]

  on_mount({NervesGateWeb.Observations, :status})

  on_mount({NervesGateWeb.Access, :network})

  def handle_params(%{"id" => id}, _, socket) do
    case Enum.find(lan_ports(socket.assigns.projection), &(&1.id == id)) do
      nil ->
        {:noreply, push_navigate(socket, to: "/equipment")}

      port ->
        {:noreply,
         assign(socket,
           name: port.name,
           editing: nil,
           label_form: nil,
           message: nil,
           scanning: false,
           sharing_busy: false
         )}
    end
  end

  # Recheck scope on every command: another session may have reassigned this port.
  def handle_event(event, params, socket) do
    projection = NervesGateWeb.Backend.status()
    scope = projection.equipment.scope

    scoped =
      scope &&
        (scope.interface == socket.assigns.name ||
           (scope.interface == "br0" && projection.connections.mode == "shared"))

    sharing = event in ["enable-sharing", "disable-sharing"]

    if equipment_port?(projection, socket.assigns.name) && (sharing || scoped) do
      port_event(event, params, socket)
    else
      {:noreply,
       assign(socket,
         editing: nil,
         label_form: nil,
         message: %{
           tone: "warning",
           text: "This LAN port is not the equipment connection. Check its network settings."
         }
       )}
    end
  end

  defp port_event("scan", _, socket) do
    {:noreply,
     socket
     |> assign(scanning: true, message: nil)
     |> start_async(:scan, fn -> NervesGateWeb.Backend.equipment_scan() end)}
  end

  defp port_event("edit-label", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.projection.equipment.entries, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      entry ->
        {:noreply,
         assign(socket,
           editing: id,
           label_form: to_form(%{"label" => entry.label}, as: :equipment),
           message: nil
         )}
    end
  end

  defp port_event("change-label", %{"equipment" => params}, socket),
    do: {:noreply, assign(socket, :label_form, to_form(params, as: :equipment))}

  defp port_event("cancel-label", _, socket),
    do: {:noreply, assign(socket, editing: nil, label_form: nil)}

  defp port_event("save-label", %{"equipment" => %{"label" => label}}, socket) do
    case NervesGateWeb.Backend.equipment_label(socket.assigns.editing, label) do
      :ok ->
        {:noreply, socket |> assign(editing: nil, label_form: nil) |> result(:ok, "Label saved.")}

      error ->
        {:noreply, result(socket, error, "")}
    end
  end

  defp port_event("enable-sharing", _, socket),
    do: change_sharing(socket, &NervesGateWeb.Backend.equipment_share/0)

  defp port_event("disable-sharing", _, socket),
    do: change_sharing(socket, &NervesGateWeb.Backend.equipment_unshare/0)

  defp port_event(_, _, socket), do: {:noreply, socket}

  defp change_sharing(socket, command),
    do:
      {:noreply,
       socket |> assign(sharing_busy: true, message: nil) |> start_async(:sharing, command)}

  def handle_async(:scan, {:ok, outcome}, socket),
    do:
      {:noreply,
       socket
       |> assign(:scanning, false)
       |> result(outcome, "Scan completed. Silent equipment may still be absent.")}

  def handle_async(:scan, {:exit, _}, socket),
    do:
      {:noreply,
       socket
       |> assign(:scanning, false)
       |> result({:error, %{message: "Scan outcome unavailable. Refresh before retrying."}}, "")}

  def handle_async(:sharing, outcome, socket) do
    outcome =
      case outcome do
        {:ok, result} ->
          result

        {:exit, _} ->
          {:error, %{message: "The reply was lost. Check sharing state before retrying."}}
      end

    {:noreply,
     socket
     |> assign(:sharing_busy, false)
     |> result(outcome, "Sharing updated. On means advertised, not verified reachable.")}
  end

  defp result(socket, outcome, success) do
    message =
      case outcome do
        :ok -> %{tone: "good", text: success}
        {:error, error} -> %{tone: "warning", text: error.message}
      end

    assign(socket, message: message)
  end

  defp equipment_port?(projection, name),
    do: Enum.any?(lan_ports(projection), &(&1.name == name && &1.role in ["equipment", "shared"]))

  defp timestamp(nil), do: "unknown (no activity timestamp)"

  defp timestamp(value),
    do: value |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

  def render(assigns) do
    port = Enum.find(lan_ports(assigns.projection), &(&1.name == assigns.name))
    equipment? = equipment_port?(assigns.projection, assigns.name)
    sharing = assigns.projection.sharing
    action = if sharing.enabled == false, do: "equipment.share", else: "equipment.unshare"

    assigns =
      assign(assigns,
        port: port,
        equipment: if(equipment?, do: equipment_interface(assigns.projection)),
        equipment_port: equipment?,
        sharing: sharing,
        sharing_action: assigns.projection.actions[action]
      )

    ~H"""
    <.link navigate="/equipment" class="ui-text-link">Back to Equipment</.link>
    <.page_header title={port_label(@name)} description="Local equipment connection." />
    <.notice :if={@projection.network.observed && @projection.network.observed.simulated}>
      Preview mode · simulated connections
    </.notice>
    <.notice :for={problem <- @projection.connections.problems} tone="warning">{problem}</.notice>
    <.notice :if={@message} tone={@message.tone} role="status">{@message.text}</.notice>
    <.panel title="Ethernet connection" icon="port" id="equipment-connection">
      <:meta>
        <.status>
          {if @projection.network.observed, do: equipment_status(@port.observed), else: "Unavailable"}
        </.status>
      </:meta>
      <%= cond do %>
        <% !@projection.network.observed -> %>
          <p>
            Connection observations are unavailable. Existing network settings have not been changed.
          </p>
        <% @port.role == "internet" -> %>
          <p>This port is dedicated to Internet access.</p>
        <% !@equipment_port -> %>
          <p>
            No equipment connection is configured on this port. Assign it an address in your equipment’s subnet.
          </p>
        <% true -> %>
          <.setting_row label="Connection">
            {if @port.role == "shared", do: "Shared network · LAN 1 + LAN 2", else: port_label(@name)}
          </.setting_row>
          <.setting_row :if={@equipment} label="Gateway address on this network">
            <span :if={@equipment.addresses == []}>No IPv4 address observed</span>
            <code :for={address <- @equipment.addresses} class="ui-port-address">{address.address}/{address.prefix_length}</code>
          </.setting_row>
          <p class="ui-help">
            A cable or gateway address does not prove that equipment is reachable.
          </p>
      <% end %>
      <.link :if={@port.role in ["internet", "shared"]} navigate="/network" class="ui-text-link">
        {if @port.role == "shared", do: "Configure shared network", else: "Configure Internet"}
      </.link>
    </.panel>
    <.live_component
      module={NervesGateWeb.NetworkEditor}
      id={"equipment-network-#{@name}"}
      editor={{:equipment, @name}}
      projection={@projection}
      access={@access}
    />
    <.panel :if={@equipment_port} title="Ethernet devices" icon="equipment" id="equipment-discovery">
      <:meta>
        <.status>{length(@projection.equipment.entries)} observed</.status>
      </:meta>
      <p :if={@port.role == "shared"} class="ui-help">
        These devices belong to the shared network, not to an individual LAN port.
      </p>
      <p class="ui-help">
        Passive neighbor-cache observations are not a complete inventory or proof of current reachability.
        Labels are stored on this gateway, scoped to this network and MAC address; they do not identify or authenticate a device.
      </p>
      <.notice :if={!@projection.equipment.available} tone="warning">
        Equipment observations are unavailable.
      </.notice>
      <.notice :if={@projection.equipment.error} tone="warning">
        {@projection.equipment.error.message}
      </.notice>
      <.notice :if={@projection.equipment.labels_error} tone="warning">
        {@projection.equipment.labels_error.message}
      </.notice>
      <div :if={@projection.equipment.scope} class="ui-stack">
        <p>
          Active scan:
          <code>{NervesGate.Equipment.Subnet.scan(@projection.equipment.scope).cidr}</code>
          on <code>{@projection.equipment.scope.interface}</code>.
          Sends ARP requests only, at most 254 hosts and five seconds. No port probes or automatic scans.
          Only scan networks you are authorized to inspect.
        </p>
        <.button
          id="scan-equipment"
          phx-click="scan"
          disabled={@scanning || !@projection.actions["equipment.scan"].enabled}
        >
          {if @scanning || @projection.equipment.operation == :scan,
            do: "Scanning…",
            else: "Scan equipment subnet"}
        </.button>
        <p :if={@projection.actions["equipment.scan"].reason} class="ui-help">
          {@projection.actions["equipment.scan"].reason.message}
        </p>
        <p :if={@projection.equipment.last_scan} class="ui-help">
          Last completed scan: {timestamp(@projection.equipment.last_scan)}
        </p>
      </div>
      <p :if={@projection.equipment.entries == []}>
        No devices observed. Silent devices may not appear, even after a scan.
      </p>
      <div
        :for={entry <- @projection.equipment.entries}
        id={"equipment-#{entry.id}"}
        class="ui-setting-row"
      >
        <div>
          <h3>{if entry.label == "", do: "Unlabelled device", else: entry.label}</h3>
          <p><code>{entry.ip}</code> · <code>{entry.mac}</code></p>
          <p class="ui-help">{entry.source} · Last seen: {timestamp(entry.last_seen)}</p>
        </div>
        <.button
          variant="quiet"
          phx-click="edit-label"
          phx-value-id={entry.id}
          disabled={!@projection.actions["equipment.label"].enabled}
        >Edit label</.button>
      </div>
      <.form
        :if={@editing}
        for={@label_form}
        id="equipment-label-form"
        phx-change="change-label"
        phx-submit="save-label"
      >
        <.field
          field={@label_form[:label]}
          label="Local label"
          help="Up to 64 characters. Leave empty to remove the label."
        />
        <div class="ui-actions">
          <.button type="submit">Save label</.button>
          <.button variant="quiet" phx-click="cancel-label">Cancel</.button>
        </div>
      </.form>
    </.panel>
    <.panel
      :if={@port.role == "equipment"}
      title="Remote access"
      icon="shield"
      id="equipment-remote-access"
    >
      <.setting_row label="Equipment subnet">
        <code :if={@sharing.subnet}>{@sharing.subnet}</code><span :if={!@sharing.subnet}>Not available</span>
      </.setting_row>
      <.setting_row label="Share equipment network">
        <strong id="equipment-sharing-state">{case @sharing.enabled do
          true -> "On"
          false -> "Off"
          nil -> "Unknown"
        end}</strong>
      </.setting_row>
      <.notice :if={@sharing.enabled == nil} tone="warning">
        Sharing state is unknown. Turn it off to verify withdrawal before changing LAN settings.
      </.notice>
      <.button
        id="equipment-sharing-toggle"
        phx-click={if @sharing.enabled == false, do: "enable-sharing", else: "disable-sharing"}
        disabled={@sharing_busy || !@sharing_action.enabled}
      >
        {cond do
          @sharing_busy -> "Updating sharing…"
          @sharing.enabled == false -> "Turn sharing on"
          true -> "Turn sharing off"
        end}
      </.button>
      <p :if={@sharing_action.reason} class="ui-help">{@sharing_action.reason.message}</p>
      <p class="ui-help">
        Use equipment’s normal IPv4 addresses. Approve this subnet in Tailscale and allow access
        in your tailnet policy, then test the equipment connection. On means advertised, not verified reachable.
      </p>
      <p class="ui-help">
        Overlapping networks are not supported. Your computer’s LAN and other VPNs must not use
        the same or an overlapping subnet. Broadcast discovery does not cross this connection.
      </p>
      <.notice :if={@sharing.other_routes != []} tone="warning">
        Other subnet routes may still provide equipment access. This control leaves them unchanged;
        remove those advertisements in Tailscale before changing LAN settings.
      </.notice>
      <.link navigate="/remote" class="ui-text-link">Manage Tailscale</.link>
    </.panel>
    """
  end
end
