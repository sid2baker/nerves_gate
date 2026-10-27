defmodule NervesGateWeb.HardwarePortLive do
  use Phoenix.LiveView
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
       draft: nil
     )}
  end

  def handle_params(%{"id" => id}, _, socket) do
    ports = %{rs485: %{"1" => "ttyS3", "2" => "ttyS4"}, can: %{"1" => "can0", "2" => "can1"}}

    case get_in(ports, [socket.assigns.live_action, id]) do
      nil ->
        {:noreply, push_navigate(socket, to: "/hardware")}

      name ->
        {:noreply,
         assign(socket,
           port_name: name,
           title: "#{if socket.assigns.live_action == :can, do: "CAN", else: "RS485"} #{id}",
           draft: nil
         )}
    end
  end

  def handle_info(:refresh_hardware, socket) do
    Process.send_after(self(), :refresh_hardware, 2_000)
    {:noreply, assign(socket, :hardware, hardware())}
  end

  def handle_event("refresh", _, socket),
    do:
      {:noreply,
       assign(socket,
         hardware: hardware(),
         uncertain?: false,
         outcome: "State refreshed. Inspect before continuing."
       )}

  def handle_event(_, _, %{assigns: %{busy: true}} = socket), do: {:noreply, socket}

  def handle_event("review", %{"assignment" => params}, socket) do
    setting =
      socket.assigns.hardware.ports[socket.assigns.port_name] || %{enabled: false, plugin: nil}

    {:noreply, assign(socket, :draft, Map.put(params, "expected", setting))}
  end

  def handle_event("confirm", _, %{assigns: %{draft: draft, uncertain?: false}} = socket)
      when is_map(draft) do
    port = socket.assigns.port_name
    enabled = draft["enabled"] == "true"
    plugin = if draft["plugin"] in [nil, ""], do: nil, else: draft["plugin"]

    {:noreply,
     socket
     |> assign(busy: true, draft: nil)
     |> start_async(:assignment, fn ->
       NervesGate.Plugins.assign_port(port, enabled, plugin, true, draft["expected"])
     end)}
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

    {:noreply,
     assign(socket,
       busy: false,
       hardware: hardware(),
       uncertain?: unknown,
       outcome:
         if(result == :ok,
           do: "Assignment saved. Affected plugins are stopped. Start/configure separately.",
           else: "Assignment failed: #{inspect(result)}"
         )
     )}
  end

  def handle_async(:assignment, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket,
         busy: false,
         uncertain?: true,
         outcome: "Outcome unknown. Refresh and inspect; nothing is retried."
       )}

  def render(assigns) do
    observed = Enum.filter(assigns.projection.hardware.ports, &(&1.name == assigns.port_name))

    ports =
      if observed == [] do
        [
          %{
            name: assigns.port_name,
            present: false,
            transport: if(assigns.live_action == :can, do: "can", else: "rs485"),
            profile: "Unavailable hardware"
          }
        ]
      else
        observed
      end

    setting = assigns.hardware.ports[assigns.port_name] || %{enabled: false, plugin: nil}

    eligible =
      for {plugin, kinds} <- assigns.hardware.capabilities,
          NervesGate.Plugins.Assignments.kind(assigns.port_name) in kinds,
          do: plugin

    assigns = assign(assigns, ports: ports, setting: setting, eligible: Enum.sort(eligible))

    ~H"""
    <.back_link navigate="/hardware">Hardware</.back_link>
    <.page_header title={@title} description={@port_name} />
    <p class="ui-help">
      Hardware permission and assignment only. Plugins own handles, protocol settings and equipment connections. Opening this page never opens a port.
    </p>
    <p :if={@outcome} role="status">{@outcome}</p>
    <p :if={@hardware.error} role="alert">
      Hardware assignments unavailable: {inspect(@hardware.error)}
    </p>
    <p :if={@uncertain?} role="alert">
      An outcome is unresolved. Refresh and inspect before continuing.
    </p>
    <button class="ui-button ui-button--secondary" phx-click="refresh" disabled={@busy}>Refresh state</button>
    <p :if={Enum.all?(@ports, &(!&1.present))}>
      Hardware is not detected on this target. Missing ports may only be disabled and unassigned.
    </p>
    <section :for={port <- @ports} class="ui-panel">
      <div class="ui-panel-body">
        <p>
          Detected: {if port.present, do: "Yes", else: "No"} · {if @setting.enabled,
            do: "Enabled",
            else: "Disabled"}
        </p>
        <p>Assigned plugin: {@setting.plugin || "Unassigned"}</p>
        <p :if={@setting.plugin}>
          Plugin state: {Map.get(Map.get(@hardware, :plugins, %{}), @setting.plugin, :unavailable)}
        </p>
        <p :if={port.transport == "rs485"}>
          {port.profile}. Only qualified automatic-direction 9600 8N1 is supported.
        </p>
        <p :if={@eligible == []}>
          No selected plugin supports this hardware kind. It may remain unassigned.
        </p>
        <form phx-submit="review" class="ui-stack">
          <label>Permission<select name="assignment[enabled]">
            <option value="false" selected={!@setting.enabled}>Disabled</option>
            <option value="true" selected={@setting.enabled}>Enabled for assigned plugin</option>
          </select></label>
          <label>Assigned plugin<select name="assignment[plugin]">
            <option value="" selected={@setting.plugin == nil}>Unassigned</option>
            <option
              :if={@setting.plugin != nil and @setting.plugin not in @eligible}
              value={@setting.plugin}
              selected
              disabled
            >
              {@setting.plugin} — unavailable
            </option>
            <option :for={plugin <- @eligible} value={plugin} selected={plugin == @setting.plugin}>
              {plugin}
            </option>
          </select></label>
          <button
            class="ui-button ui-button--primary"
            disabled={@busy or @uncertain? or @hardware.error != nil or @hardware.operation}
          >Review assignment</button>
        </form>
      </div>
    </section>
    <section :if={@draft} class="ui-panel" id="assignment-review">
      <div class="ui-panel-body">
        <p>
          Assign {@port_name} to {if @draft["plugin"] in [nil, ""],
            do: "Unassigned",
            else: @draft["plugin"]}; enabled: {@draft["enabled"]}.
        </p>
        <p role="alert">
          This stops both the old and new owning plugin if running, interrupting ALL their ports and connections. Cleanup must succeed before assignment changes. Both remain stopped. No traffic is started.
        </p>
        <button
          class="ui-button ui-button--primary"
          phx-click="confirm"
          disabled={@busy or @uncertain?}
        >Stop affected plugins and apply</button>
        <button class="ui-button ui-button--secondary" phx-click="cancel" disabled={@busy}>Cancel</button>
      </div>
    </section>
    """
  end

  defp hardware do
    NervesGate.Plugins.hardware()
  catch
    :exit, _ -> %{ports: %{}, capabilities: %{}, error: :unavailable, operation: false}
  end
end
