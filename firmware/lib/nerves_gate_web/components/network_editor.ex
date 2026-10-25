defmodule NervesGateWeb.NetworkEditor do
  @moduledoc "Network drafts, explicit SIM-unlock intent and the device-owned trial workflow."
  use Phoenix.LiveComponent
  alias NervesGate.Network
  alias NervesGateWeb.{CellularPanel, NetworkForm, NetworkStatus}
  import NervesGateWeb.CoreComponents

  def update(%{tick: true}, socket),
    do: {:ok, socket |> assign(ticking: false, now: System.system_time(:millisecond)) |> tick()}

  def update(assigns, %{assigns: %{base: _}} = socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:projection]))
      |> assign(:now, System.system_time(:millisecond))

    {:ok, socket |> refresh_observations(assigns.projection) |> continue_unlock() |> tick()}
  end

  def update(assigns, socket) do
    projection = assigns.projection
    settings = Map.get(assigns, :settings, false)

    socket =
      socket
      |> assign(assigns)
      |> assign(
        settings: settings,
        form:
          to_form(NetworkForm.from_settings(projection.network.desired, assigns.editor),
            as: :network
          ),
        base: projection.network.desired,
        dirty: false,
        own_save: false,
        saving_network: nil,
        initial: not projection.network.setup_completed,
        step: if(settings, do: 2, else: if(projection.network.setup_completed, do: 0, else: 1)),
        generation: 0,
        awaiting_unlock: nil,
        message: nil,
        ticking: false,
        now: System.system_time(:millisecond)
      )

    {:ok, tick(socket)}
  end

  defp tick(socket) do
    if connected?(socket) and socket.assigns.projection.network.pending != nil and
         !socket.assigns.ticking do
      send_update_after(__MODULE__, %{id: socket.assigns.id, tick: true}, 1_000)
      assign(socket, :ticking, true)
    else
      socket
    end
  end

  def handle_event("change", %{"network" => params}, socket),
    do:
      {:noreply,
       assign(socket,
         form: draft(socket, params),
         dirty: true,
         message: nil,
         awaiting_unlock: nil
       )}

  def handle_event("start-setup", _, socket),
    do: {:noreply, socket |> reset_draft() |> assign(step: 1)}

  def handle_event("back", _, socket),
    do: {:noreply, assign(socket, step: 1, awaiting_unlock: nil)}

  def handle_event("reload", _, socket), do: {:noreply, reset_draft(socket)}

  def handle_event("finish-setup", _, socket) do
    if socket.assigns.projection.network.pending == nil and !socket.assigns.own_save,
      do: {:noreply, socket |> reset_draft() |> assign(step: 0)},
      else: {:noreply, socket}
  end

  def handle_event(
        "save",
        %{"network" => params},
        %{assigns: %{editor: :internet, step: 1}} = socket
      ) do
    socket =
      assign(socket, form: draft(socket, params), dirty: true, step: 2, awaiting_unlock: nil)

    if socket.assigns.form.params["internet_mode"] == "cellular" and
         socket.assigns.projection.cellular.sim == :ready,
       do: {:noreply, apply_network(socket)},
       else: {:noreply, socket}
  end

  def handle_event("save", %{"network" => params}, socket),
    do:
      {:noreply,
       socket |> assign(form: draft(socket, params), awaiting_unlock: nil) |> apply_network()}

  def handle_event("confirm", params, socket),
    do: network_reply(socket, Network.confirm(params["trial_id"]))

  def handle_event("cancel", params, socket),
    do: network_reply(assign(socket, own_save: false), Network.cancel(params["trial_id"]))

  def handle_event("unlock-connect", params, socket) do
    with true <- socket.assigns.editor == :internet and socket.assigns.step == 2,
         true <- socket.assigns.form.params["internet_mode"] in ["cellular", "backup"],
         {:ok, _} <- candidate(socket),
         {:ok, id} <- NervesGate.Cellular.unlock(params["pin"], track: true) do
      {:noreply,
       assign(socket,
         generation: socket.assigns.generation + 1,
         awaiting_unlock: id,
         message: nil
       )}
    else
      {:error, error} -> cellular_reply(socket, {:error, error})
      _ -> cellular_reply(socket, {:error, "Choose a 4G source before connecting."})
    end
  end

  def handle_event("unlock", params, socket),
    do: cellular_reply(socket, NervesGate.Cellular.unlock(params["pin"]))

  def handle_event("save_pin", params, socket),
    do: cellular_reply(socket, NervesGate.Cellular.save_pin(params["pin"]))

  def handle_event("forget_pin", _, socket),
    do: cellular_reply(socket, NervesGate.Cellular.forget_pin())

  def handle_event("refresh", _, socket),
    do: cellular_reply(socket, NervesGate.Cellular.refresh())

  def handle_event("reconnect", _, socket),
    do: cellular_reply(socket, NervesGate.Cellular.reconnect())

  def handle_event("forget_authentication", _, socket),
    do: cellular_reply(socket, NervesGate.Cellular.forget_authentication())

  def handle_event("save_authentication", params, socket) do
    apn = String.trim(socket.assigns.form.params["cellular_apn"] || "")

    result =
      if params["apn"] == apn,
        do: NervesGate.Cellular.save_authentication(apn, params["username"], params["password"]),
        else: {:error, "The APN draft changed. Check it before saving credentials."}

    cellular_reply(socket, result)
  end

  defp cellular_reply(socket, result) do
    message =
      case result do
        :ok -> nil
        {:error, %{message: message}} -> message
        {:error, message} when is_binary(message) -> message
      end

    {:noreply,
     assign(socket,
       generation: socket.assigns.generation + 1,
       awaiting_unlock: nil,
       message: message
     )}
  end

  defp continue_unlock(%{assigns: %{awaiting_unlock: nil}} = socket), do: socket

  defp continue_unlock(socket) do
    cellular = socket.assigns.projection.cellular

    case cellular.result do
      %{id: id, operation: :unlock, error: nil}
      when id == socket.assigns.awaiting_unlock and cellular.operation != nil ->
        socket

      %{id: id, operation: :unlock, error: error} when id == socket.assigns.awaiting_unlock ->
        socket = assign(socket, awaiting_unlock: nil)

        if error == nil and cellular.sim == :ready,
          do: apply_network(socket),
          else:
            assign(socket,
              message: "SIM unlock did not complete safely. Read the result before acting again."
            )

      %{id: id} when is_integer(id) and id > socket.assigns.awaiting_unlock ->
        assign(socket,
          awaiting_unlock: nil,
          message:
            "Cellular state changed in another session. Check the SIM and connect again; do not repeat an accepted PIN."
        )

      _ ->
        socket
    end
  end

  defp candidate(socket),
    do:
      NetworkForm.to_network(
        socket.assigns.form.params,
        socket.assigns.projection.connections.ports,
        socket.assigns.base,
        socket.assigns.editor
      )

  defp apply_network(socket) do
    with :ok <- sim_ready(socket), {:ok, network} <- candidate(socket) do
      result =
        Network.propose(network, access: socket.assigns.access, expected: socket.assigns.base)

      {:noreply, socket} =
        network_reply(assign(socket, own_save: true, saving_network: network), result)

      socket
    else
      {:error, message} -> assign(socket, dirty: true, message: message)
    end
  end

  defp sim_ready(%{assigns: %{editor: :internet}} = socket) do
    if socket.assigns.form.params["internet_mode"] in ["cellular", "backup"] and
         socket.assigns.projection.cellular.sim != :ready,
       do: {:error, "Unlock the SIM before connecting. Current LAN settings have not changed."},
       else: :ok
  end

  defp sim_ready(_), do: :ok

  defp network_reply(socket, {:ok, _}), do: network_reply(socket, :ok)

  defp network_reply(socket, :ok) do
    socket =
      if socket.assigns.editor == :internet and socket.assigns.own_save,
        do: assign(socket, step: 3),
        else: socket

    {:noreply, socket}
  end

  defp network_reply(socket, {:error, error}),
    do: {:noreply, assign(socket, own_save: false, dirty: true, message: error.message)}

  @doc false
  def refresh_observations(socket, %{device: %{available: false}} = projection),
    do: assign(socket, projection: projection, awaiting_unlock: nil)

  def refresh_observations(socket, projection) do
    previous = socket.assigns.projection.network
    network = projection.network
    socket = assign(socket, projection: projection, initial: not network.setup_completed)

    cond do
      saved?(socket.assigns, network, previous) ->
        saved(socket, network)

      socket.assigns.own_save and previous.pending != nil and network.pending == nil ->
        assign(socket, own_save: false)

      !socket.assigns.dirty and network.desired != socket.assigns.base ->
        reset_draft(socket)

      true ->
        socket
    end
  end

  defp saved?(assigns, network, previous),
    do:
      assigns.own_save and network.pending == nil and network.setup_completed and
        network.error == nil and
        network.desired == assigns.saving_network and
        (previous.pending != nil or previous.desired != network.desired or
           previous.setup_completed != network.setup_completed)

  defp saved(socket, network),
    do:
      socket
      |> reset_draft()
      |> assign(
        own_save: false,
        initial: false,
        base: network.desired,
        message: "Settings saved."
      )

  defp reset_draft(socket) do
    network = socket.assigns.projection.network.desired

    assign(socket,
      form: to_form(NetworkForm.from_settings(network, socket.assigns.editor), as: :network),
      base: network,
      dirty: false,
      message: nil,
      awaiting_unlock: nil
    )
  end

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

  def render(assigns) do
    assigns =
      assign(assigns,
        settings: Map.get(assigns, :settings, false),
        cellular: Map.merge(NervesGate.Cellular.view(nil), assigns.projection.cellular),
        stale: assigns.base != assigns.projection.network.desired,
        pending: assigns.projection.network.pending,
        mobile:
          assigns.editor == :internet and
            assigns.form.params["internet_mode"] in ["cellular", "backup"],
        cellular_available:
          assigns.projection.capabilities.mobile and
            match?(%{cellular: %{present: true}}, assigns.projection.network.observed),
        equipment_reason:
          NetworkForm.equipment_reason(assigns.projection.network.desired, assigns.editor)
      )

    ~H"""
    <div id={@id} class="ui-stack">
      <.notice :if={@message != nil} role="status">{@message}</.notice>
      <.notice :if={@projection.network.error != nil} tone="warning" role="alert">
        {@projection.network.error.message}
      </.notice>
      <%= cond do %>
        <% !@projection.network.available or @projection.network.desired == nil -> %>
          <.notice tone="warning">
            Saved settings are unavailable. They have not been overwritten. Reconnect before editing.
          </.notice>
        <% @pending != nil -> %>
          <.trial pending={@pending} projection={@projection} now={@now} target={@myself} />
        <% @editor == :internet and @step in [0, 3] -> %>
          <p :if={@own_save} role="status">Connecting…</p>
        <% @equipment_reason != nil -> %>
          <.notice tone="warning">{@equipment_reason}</.notice>
        <% true -> %>
          <.notice :if={@stale} tone="warning">
            Settings changed in another session. Your draft has not been applied.
            <.button variant="secondary" phx-target={@myself} phx-click="reload">Reload saved settings</.button>
          </.notice>
          <.form
            for={@form}
            id={form_id(@editor)}
            phx-target={@myself}
            phx-change="change"
            phx-submit="save"
            class="ui-stack"
          >
            <%= case @editor do %>
              <% :internet -> %>
                <.internet_form
                  form={@form}
                  projection={@projection}
                  base={@base}
                  initial={@initial}
                  step={@step}
                  settings={@settings}
                  cellular_available={@cellular_available}
                />
              <% :ports -> %>
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
                  <.notice :if={@form.params["mode"] == "shared"} tone="warning">
                    Only join ports on the same trusted network. Separate port assignments are replaced.
                  </.notice>
                  <.address_fields
                    :if={@form.params["mode"] == "shared"}
                    form={@form}
                    prefix="shared"
                  />
                  <.notice
                    :if={@form.params["mode"] != "shared" and @base["mode"] == "shared"}
                    tone="warning"
                  >
                    Separating removes the shared address and leaves both ports unassigned.
                  </.notice>
                </.panel>
              <% _ -> %>
                <.equipment_form form={@form} />
            <% end %>
            <.notice :if={!@projection.actions["network.propose"].enabled} tone="warning">
              {@projection.actions["network.propose"].reason.message}
            </.notice>
            <div class="ui-actions">
              <.button
                :if={!@mobile or @step == 1 or @cellular.sim != :pin_required or @settings}
                id="apply-settings"
                type="submit"
                phx-disable-with="Working…"
                disabled={
                  @stale or !@projection.actions["network.propose"].enabled or
                    (@mobile and (!@cellular_available or (@step == 2 and @cellular.sim != :ready))) or
                    @awaiting_unlock != nil
                }
              >{submit_label(@editor, @step, @settings, @form.params)}</.button>
              <.button
                :if={@editor == :internet and @step == 2 and !@settings}
                phx-click="back"
                phx-target={@myself}
                variant="secondary"
              >Back</.button>
              <.button
                :if={@editor == :internet and !@initial and !@settings}
                phx-click="finish-setup"
                phx-target={@myself}
                variant="quiet"
              >Cancel</.button>
              <.button :if={@initial and @editor == :internet} href="/" variant="quiet">Finish offline</.button>
            </div>
          </.form>
      <% end %>
      <CellularPanel.sim
        :if={@editor == :internet and @step == 2 and @mobile and @pending == nil}
        projection={@projection}
        target={@myself}
        generation={@generation}
        connect={!@settings}
        settings={@settings}
        custom={@form.params["cellular_profile"] == "custom"}
        apn={String.trim(@form.params["cellular_apn"] || "")}
      />
      <div
        :if={@editor == :internet and (@step in [0, 3] or @pending != nil)}
        id="internet-live-status"
        class="ui-stack"
      >
        <NetworkStatus.internet_summary projection={@projection} />
        <.notice
          :if={
            @cellular.result != nil and
              @projection.connections.internet.mode in ["cellular", "backup"] and
              @cellular.result.error != nil
          }
          tone="warning"
          role="alert"
        >
          {CellularPanel.result_message(@cellular.result)}
        </.notice>
        <CellularPanel.sim
          :if={
            @projection.connections.internet.mode in ["cellular", "backup"] and
              @cellular.sim != :ready and @pending == nil
          }
          projection={@projection}
          target={@myself}
          generation={@generation}
        />
        <p
          :if={
            @projection.connections.internet.mode in ["cellular", "backup"] and
              @cellular.sim == :ready and @projection.connections.internet.cellular != :internet
          }
          class="ui-help"
        >
          Internet is not yet verified over 4G. If it stays unavailable, choose your carrier in Connection settings.
        </p>
        <div :if={@pending == nil} class="ui-actions">
          <.button
            :if={!@own_save}
            id="internet-change-setup"
            phx-click="start-setup"
            phx-target={@myself}
          >Change setup</.button>
          <.button
            :if={@step == 3 and !@own_save and @projection.network.setup_completed}
            id="internet-finish"
            phx-click="finish-setup"
            phx-target={@myself}
          >Done</.button>
          <.button :if={@step == 3 and !@own_save and @initial} href="/" variant="quiet">Finish offline</.button>
        </div>
      </div>
      <.link
        :if={@editor == :internet and !@settings}
        navigate="/network/details"
        class="ui-text-link"
      >Connection settings →</.link>
      <NetworkStatus.lan_internet :if={@editor == :internet and @settings} projection={@projection} />
    </div>
    """
  end

  defp internet_form(assigns) do
    assigns =
      assign(assigns, :options, Map.get(assigns.projection.cellular, :provider_options, []))

    ~H"""
    <.panel
      title={
        if @step == 1,
          do: "Internet source",
          else: if(@settings, do: "Connection settings", else: "Connect")
      }
      icon="internet"
    >
      <.choice_group :if={@step == 1 or @settings} field={@form[:internet_mode]} label="Connect using">
        <:option value="ethernet" title="LAN" description="Use a LAN port for Internet." />
        <:option
          value="cellular"
          title="4G"
          description="Use your SIM."
          disabled={!@cellular_available}
        />
        <:option
          value="backup"
          title="LAN with 4G backup"
          description="Use 4G when LAN has no Internet."
          disabled={!@cellular_available}
        />
      </.choice_group>
      <.notice :if={(@step == 1 or @settings) and !@cellular_available}>
        {if @projection.capabilities.mobile,
          do: "No 4G modem detected.",
          else: "4G is not supported on this device."}
      </.notice>
      <div :if={@step == 2} class="ui-stack">
        <div
          :if={@form.params["internet_mode"] != "cellular" and @base["mode"] != "shared"}
          id="internet-options"
          class="ui-stack"
        >
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
            :if={@settings and @form.params["internet_port"] != ""}
            form={@form}
            prefix="internet"
          />
        </div>
        <p
          :if={@form.params["internet_mode"] != "cellular" and @base["mode"] == "shared"}
          class="ui-help"
        >
          LAN ports are joined. Their addressing is configured in Settings.
        </p>
        <p
          :if={@form.params["internet_mode"] in ["cellular", "backup"] and !@settings}
          class="ui-help"
        >
          Carrier settings are automatic. Unlock your SIM below if needed; LAN stays unchanged until connecting.
        </p>
        <div
          :if={@settings and @form.params["internet_mode"] in ["cellular", "backup"]}
          class="ui-stack"
        >
          <label for="network-cellular-profile">Carrier / plan</label>
          <select id="network-cellular-profile" name={@form[:cellular_profile].name}>
            <option value="auto" selected={@form.params["cellular_profile"] == "auto"}>
              Automatic from SIM
            </option>
            <option
              :for={option <- @options}
              value={"provider:" <> option["id"]}
              selected={@form.params["cellular_profile"] == "provider:" <> option["id"]}
            >
              {option["name"]} · {option["plan"]} ({option["apn"]})
            </option>
            <option
              :if={missing_profile?(@form.params["cellular_profile"], @options)}
              value={@form.params["cellular_profile"]}
              selected
            >
              Saved carrier (not available for this SIM)
            </option>
            <option value="custom" selected={@form.params["cellular_profile"] == "custom"}>
              Other / private APN
            </option>
          </select>
          <.field
            :if={@form.params["cellular_profile"] == "custom"}
            field={@form[:cellular_apn]}
            label="APN from your carrier"
            autocomplete="off"
          />
          <p class="ui-help">
            Built-in carrier settings include public APN defaults. If Automatic cannot identify your plan, choose its name; only private or unlisted plans need manual settings.
          </p>
        </div>
        <p :if={@form.params["internet_mode"] == "backup"} class="ui-help">
          4G standby and checks can use mobile data.
        </p>
      </div>
    </.panel>
    """
  end

  defp trial(assigns) do
    ~H"""
    <.panel
      title={if @pending.auto_save, do: "Saving settings…", else: "Keep these changes?"}
      icon="clock"
    >
      <%= if @pending.auto_save do %>
        <p>Applying connections. USB stays available; no confirmation is needed.</p>
      <% else %>
        <p>
          <span role="timer">{max(0, div(@pending.expires_at - @now + 999, 1000))}</span>
          seconds before previous settings return automatically.
        </p>
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
            phx-target={@target}
            phx-value-trial_id={@pending.id}
            disabled={!@projection.actions["network.confirm"].enabled}
          >Keep changes</.button>
          <.button
            phx-click="cancel"
            phx-target={@target}
            phx-value-trial_id={@pending.id}
            variant="secondary"
          >Restore previous settings</.button>
        </div>
      <% end %>
    </.panel>
    """
  end

  defp equipment_form(assigns) do
    ~H"""
    <.panel title="Equipment network" icon="equipment">
      <.choice_group field={@form[:enabled]} label="Use this LAN port">
        <:option
          value="true"
          title="Equipment"
          description="Assign an address on your equipment’s network."
        />
        <:option value="false" title="Not configured" description="Leave this port unused." />
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
        <.field field={@form[:equipment_mask]} label="Subnet mask" required autocomplete="off" />
      </div>
      <p class="ui-help">Equipment keeps its own addresses; Internet settings are preserved.</p>
    </.panel>
    """
  end

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

  defp form_id(:internet), do: "network-form"
  defp form_id(:ports), do: "lan-ports-form"
  defp form_id(_), do: "equipment-network-form"
  defp submit_label(:internet, 1, _, %{"internet_mode" => "cellular"}), do: "Connect"
  defp submit_label(:internet, 1, _, _), do: "Continue"
  defp submit_label(:internet, _, false, _), do: "Connect"
  defp submit_label(_, _, _, _), do: "Apply changes"
  defp missing_profile?("provider:" <> id, options), do: !Enum.any?(options, &(&1["id"] == id))
  defp missing_profile?(_, _), do: false

  defp internet_status(name, ports) do
    case Enum.find(ports, &(&1.name == name)) do
      nil -> "Not installed"
      port -> Network.Suggestions.status(port)
    end
  end
end
