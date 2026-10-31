defmodule NervesGateWeb.HardwarePortLive do
  use Phoenix.LiveView, log: false
  import NervesGateWeb.CoreComponents
  on_mount({NervesGateWeb.Observations, :status})

  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_hardware, 2_000)

    {:ok,
     assign(socket,
       hardware: hardware(),
       busy: false,
       uncertain?: false,
       outcome: nil,
       draft: nil,
       assignment_form: nil,
       requested_plugin: nil
     )}
  end

  def handle_params(%{"id" => id} = params, _, socket) do
    ports = %{
      lan: %{"1" => "eth0", "2" => "eth1"},
      rs485: %{"1" => "ttyS3", "2" => "ttyS4"},
      can: %{"1" => "can0", "2" => "can1"}
    }

    case get_in(ports, [socket.assigns.live_action, id]) do
      nil ->
        {:noreply, push_navigate(socket, to: "/hardware")}

      name ->
        plugin = params["plugin"]
        requested = if is_binary(plugin) and NervesGateSDK.Package.valid_name?(plugin), do: plugin

        {:noreply,
         assign(socket,
           port_name: name,
           title: "#{socket.assigns.live_action |> Atom.to_string() |> String.upcase()} #{id}",
           requested_plugin: requested,
           assignment_form: nil,
           draft: nil
         )}
    end
  end

  def handle_info(:refresh_hardware, socket) do
    Process.send_after(self(), :refresh_hardware, 2_000)
    {:noreply, assign(socket, :hardware, hardware())}
  end

  def handle_event(_, _, %{assigns: %{busy: true}} = socket), do: {:noreply, socket}

  def handle_event("refresh", _, socket),
    do:
      {:noreply,
       assign(socket,
         hardware: hardware(),
         outcome: "State refreshed. Inspect before continuing.",
         draft: nil
       )}

  def handle_event("edit_assignment", %{"assignment" => params}, socket),
    do:
      {:noreply,
       assign(socket, assignment_form: Map.take(params, ["plugin", "start_plugin"]), draft: nil)}

  def handle_event("review", %{"assignment" => params}, %{assigns: %{uncertain?: false}} = socket) do
    setting =
      socket.assigns.hardware.ports[socket.assigns.port_name] || %{enabled: false, plugin: nil}

    {enabled, plugin, start?} =
      case params["action"] do
        "release" -> {false, nil, false}
        "disable" -> {false, setting.plugin, false}
        "enable" -> {true, setting.plugin, params["start_plugin"] == "true"}
        _ -> {true, params["plugin"], params["start_plugin"] == "true"}
      end

    case NervesGate.Plugins.review_assignment(socket.assigns.port_name, enabled, plugin, start?) do
      {:ok, review} ->
        {:noreply, assign(socket, draft: review, outcome: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, draft: nil, outcome: "Review rejected: #{inspect(reason)}")}
    end
  end

  def handle_event("confirm", _, %{assigns: %{draft: review, uncertain?: false}} = socket)
      when is_map(review) do
    {:noreply,
     socket
     |> assign(busy: true, draft: nil)
     |> start_async(:assignment, fn -> NervesGate.Plugins.confirm_assignment(review) end)}
  end

  def handle_event("cancel", _, socket), do: {:noreply, assign(socket, :draft, nil)}
  def handle_event(_, _, socket), do: {:noreply, socket}

  def handle_async(:assignment, {:ok, result}, socket) do
    unknown =
      result in [
        {:error, :operation_timeout},
        {:error, :lifecycle_failed},
        {:error, :metadata_commit_unknown}
      ]

    message =
      case result do
        :ok ->
          "Assignment saved. No connection or sharing command was started."

        {:error, {:assignment_saved_start_failed, reason}} ->
          "Assignment saved, but plugin start failed: #{inspect(reason)}. Inspect Plugins before continuing."

        _ ->
          "Assignment did not complete: #{inspect(result)}. Inspect current state; nothing is retried."
      end

    {:noreply,
     assign(socket, busy: false, hardware: hardware(), uncertain?: unknown, outcome: message)}
  end

  def handle_async(:assignment, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket,
         busy: false,
         uncertain?: true,
         outcome: "Outcome unknown. Inspect Plugins before continuing; nothing is retried."
       )}

  def render(assigns) do
    observed = Enum.find(assigns.projection.hardware.ports, &(&1.name == assigns.port_name))
    setting = assigns.hardware.ports[assigns.port_name] || %{enabled: false, plugin: nil}

    eligible =
      for {plugin, kinds} <- assigns.hardware.capabilities,
          NervesGate.Plugins.Assignments.kind(assigns.port_name) in kinds,
          do: plugin

    requested = Map.get(assigns, :requested_plugin)
    form = assignment_form(Map.get(assigns, :assignment_form), requested, setting, eligible)
    selected = form["plugin"]
    start? = form["start_plugin"] == "true"
    network = if assigns.live_action == :lan, do: assigns.projection.network.desired

    reserved =
      assigns.live_action == :lan and
        (network["mode"] != "ports" or
           NervesGate.Config.role_port(network, "internet") == assigns.port_name)

    assigns =
      assign(assigns,
        port: observed,
        setting: setting,
        eligible: Enum.sort(eligible),
        selected: selected,
        start_plugin?: start?,
        reserved: reserved,
        return_plugin: requested || setting.plugin
      )

    ~H"""
    <.back_link navigate="/hardware">Hardware</.back_link>
    <.page_header title={@title} description={@port_name} />
    <p class="ui-help">
      Assign access here; configure equipment in its plugin. Assignment is not a connection. Opening this page never opens a port.
    </p>
    <.notice :if={@reserved} tone="warning" id="hardware-reserved">
      This interface is reserved for Internet or is not yet an independent LAN.
      <.link navigate="/network" class="ui-text-link">Manage Internet</.link>
    </.notice>
    <p :if={@outcome} role="status">{@outcome}</p>
    <p :if={@hardware.error} role="alert">
      Hardware assignments unavailable: {inspect(@hardware.error)}
    </p>
    <p :if={@uncertain?} role="alert">
      An outcome is unresolved. Inspect Plugins; this page will not admit another operation.
    </p>
    <button class="ui-button ui-button--secondary" phx-click="refresh" disabled={@busy}>Refresh state</button>
    <section class="ui-panel">
      <div class="ui-panel-body">
        <p>Detected: {if @port && @port.present, do: "Yes", else: "No"}</p>
        <p>Assigned plugin: {@setting.plugin || "Unassigned"}</p>
        <p>Access: {if @setting.enabled, do: "Enabled", else: "Disabled"}</p>
        <p :if={@setting.plugin}>
          Plugin state: {Map.get(Map.get(@hardware, :plugins, %{}), @setting.plugin, :unavailable)}
        </p>
        <p :if={!@port || !@port.present}>
          Missing hardware can be released, but not newly assigned or enabled.
        </p>
        <p :if={@port && Map.get(@port, :profile)}>{@port.profile}</p>
        <form
          :if={!@reserved}
          id="hardware-assignment-form"
          phx-change="edit_assignment"
          phx-submit="review"
          class="ui-stack"
        >
          <label>Assign to plugin<select name="assignment[plugin]">
            <option value="">Select plugin</option>
            <option :for={plugin <- @eligible} value={plugin} selected={plugin == @selected}>
              {plugin}
            </option>
          </select></label>
          <label><input type="hidden" name="assignment[start_plugin]" value="false" /><input
            type="checkbox"
            name="assignment[start_plugin]"
            value="true"
            checked={@start_plugin?}
          />Start the target plugin after assignment (optional)</label>
          <p class="ui-help">
            Plugin startup can have plugin-defined effects. Modbus and Tailnet startup do not start connections or sharing. Never starts the previous owner.
          </p>
          <button
            class="ui-button ui-button--primary"
            name="assignment[action]"
            value="assign"
            disabled={@busy or @uncertain? or @hardware.error != nil or @hardware.operation}
          >Review assignment</button>
        </form>
        <details :if={@setting.plugin} id="hardware-advanced">
          <summary>Release or maintenance access</summary>
          <form phx-submit="review" class="ui-actions">
            <button
              class="ui-button ui-button--secondary"
              name="assignment[action]"
              value="release"
              disabled={@busy or @uncertain?}
            >Review release</button>
            <button
              :if={@setting.enabled}
              class="ui-button ui-button--secondary"
              name="assignment[action]"
              value="disable"
              disabled={@busy or @uncertain?}
            >Review disable access</button>
            <button
              :if={!@setting.enabled}
              class="ui-button ui-button--secondary"
              name="assignment[action]"
              value="enable"
              disabled={@busy or @uncertain?}
            >Review enable access</button>
          </form>
        </details>
      </div>
    </section>
    <section :if={is_map(@draft)} class="ui-panel" id="assignment-review">
      <div class="ui-panel-body">
        <p>
          Assign {@draft.port} to {@draft.setting.plugin || "Unassigned"}; access {if @draft.setting.enabled,
            do: "enabled",
            else: "disabled"}.
        </p>
        <p :if={@draft.changed?} role="alert">
          This stops affected plugins: {Enum.join(@draft.affected, ", ")}. ALL their ports and connections are interrupted. Cleanup must succeed before ownership changes.
        </p>
        <ul :if={@draft.changed?}>
          <li :for={{plugin, ports} <- @draft.affected_ports}>
            {plugin}: assigned ports {if ports == [], do: "none", else: Enum.join(ports, ", ")}; all its connections stop, including TCP.
          </li>
        </ul>
        <p :if={!@draft.changed?}>
          Ownership and access are unchanged; no unnecessary stop or restart.
        </p>
        <p :if={@draft.start_plugin?}>
          Explicitly start {@draft.setting.plugin} after assignment. The previous owner is not restarted.
        </p>
        <p :if={!@draft.start_plugin?}>
          Affected plugins remain stopped. No connection or sharing command is replayed.
        </p>
        <button
          class="ui-button ui-button--primary"
          phx-click="confirm"
          disabled={@busy or @uncertain?}
        >Confirm reviewed operation</button>
        <button class="ui-button ui-button--secondary" phx-click="cancel" disabled={@busy}>Cancel</button>
      </div>
    </section>
    <.link
      :if={@return_plugin && !@busy}
      navigate={"/plugins/#{@return_plugin}"}
      class="ui-button ui-button--secondary"
    >Open plugin / return to setup</.link>
    <.link navigate="/plugins" class="ui-text-link">Inspect or start plugins</.link>
    """
  end

  defp assignment_form(form, _, _, _) when is_map(form), do: form

  defp assignment_form(_, requested, setting, eligible),
    do: %{
      "plugin" => if(requested in eligible, do: requested, else: setting.plugin),
      "start_plugin" => "false"
    }

  defp hardware do
    NervesGate.Plugins.hardware()
  catch
    :exit, _ -> %{ports: %{}, capabilities: %{}, error: :unavailable, operation: false}
  end
end
