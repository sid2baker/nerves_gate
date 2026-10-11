defmodule NervesGateWeb.EquipmentLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents

  import NervesGateWeb.NetworkStatus,
    only: [equipment_interface: 1, equipment_status: 1, port_label: 1]

  on_mount({NervesGateWeb.Observations, :status})

  def mount(_, _, socket),
    do: {:ok, assign(socket, editing: nil, label_form: nil, message: nil, scanning: false)}

  def handle_event("scan", _, socket) do
    {:noreply,
     socket
     |> assign(scanning: true, message: nil)
     |> start_async(:scan, fn -> NervesGate.equipment_scan() end)}
  end

  def handle_event("edit-label", %{"id" => id}, socket) do
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

  def handle_event("change-label", %{"equipment" => params}, socket),
    do: {:noreply, assign(socket, :label_form, to_form(params, as: :equipment))}

  def handle_event("cancel-label", _, socket),
    do: {:noreply, assign(socket, editing: nil, label_form: nil)}

  def handle_event("save-label", %{"equipment" => %{"label" => label}}, socket) do
    case NervesGate.equipment_label(socket.assigns.editing, label) do
      :ok ->
        {:noreply, socket |> assign(editing: nil, label_form: nil) |> result(:ok, "Label saved.")}

      error ->
        {:noreply, result(socket, error, "")}
    end
  end

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

  defp result(socket, outcome, success) do
    message =
      case outcome do
        :ok -> %{tone: "good", text: success}
        {:error, error} -> %{tone: "warning", text: error.message}
      end

    assign(socket, projection: NervesGate.status(), message: message)
  end

  defp timestamp(nil), do: "unknown (no activity timestamp)"

  defp timestamp(value),
    do: value |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

  def render(assigns) do
    assigns = assign(assigns, equipment: equipment_interface(assigns.projection))

    ~H"""
    <.page_header
      title="Equipment"
      description="Discover and label devices on the local equipment connection."
    />
    <.notice :if={@projection.network.observed && @projection.network.observed.simulated}>
      Preview mode · simulated connections
    </.notice>
    <.notice :if={@projection.network.error} tone="warning" role="alert">
      {@projection.network.error.message}
    </.notice>
    <.notice :for={problem <- @projection.connections.problems} tone="warning">{problem}</.notice>
    <.panel title="Ethernet connection" icon="equipment" id="equipment-connection">
      <:meta>
        <.status>
          {if @projection.network.observed, do: equipment_status(@equipment), else: "Unavailable"}
        </.status>
      </:meta>
      <%= cond do %>
        <% !@projection.network.observed -> %>
          <p>
            Connection observations are unavailable. Existing network settings have not been changed.
          </p>
        <% @equipment == nil -> %>
          <p>
            No equipment connection is configured. Assign an Ethernet port and an address in your equipment’s subnet in Settings.
          </p>
        <% true -> %>
          <.setting_row label="Connection">
            {if @projection.connections.mode == "shared",
              do: "Shared network · Port 1 + Port 2",
              else: port_label(@equipment.name)}
          </.setting_row>
          <.setting_row label="Gateway address on this network">
            <span :if={@equipment.addresses == []}>No IPv4 address observed</span>
            <code :for={address <- @equipment.addresses} class="ui-port-address">{address.address}/{address.prefix_length}</code>
          </.setting_row>
          <p class="ui-help">
            A cable or gateway address does not prove that equipment is reachable.
          </p>
      <% end %>
      <.link navigate="/settings/network" class="ui-text-link">Configure network in Settings</.link>
    </.panel>
    <.panel title="Ethernet devices" icon="network" id="equipment-discovery">
      <:meta>
        <.status>{length(@projection.equipment.entries)} observed</.status>
      </:meta>
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
      <.notice :if={@message} tone={@message.tone} role="status">{@message.text}</.notice>
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
    <section class="ui-connections" aria-label="Equipment access">
      <.navigation_card title="Remote access" icon="shield" href="/remote">
        Gateway access and advertised equipment routes through Tailscale.
      </.navigation_card>
    </section>
    """
  end
end
