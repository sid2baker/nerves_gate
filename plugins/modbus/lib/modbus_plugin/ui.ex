defmodule ModbusPlugin.UI do
  @moduledoc "Plugin-owned drafts and controls; commands run in the supervised controller."
  use Phoenix.LiveComponent

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:devices, &devices/0)
     |> assign_new(:ports, &ports/0)
     |> assign_new(:message, fn -> nil end)
     |> assign_new(:uncertain?, fn -> false end)
     |> assign_new(:form, fn ->
       to_form(
         %{
           "transport" => "tcp",
           "serial_port" => "",
           "authorized" => "false",
           "id" => "device1",
           "host" => "",
           "port" => "502",
           "unit" => "1",
           "table" => "holding",
           "address" => "0",
           "count" => "2",
           "interval" => "1000",
           "timeout" => "1000"
         },
         as: :device
       )
     end)}
  end

  def render(assigns) do
    ~H"""
    <section class="ui-panel" id="modbus-plugin">
      <div class="ui-panel-body">
        <h2>Modbus TCP / RTU</h2>
        <p class="ui-help">
          Read-only holding/input registers using yamodbus. Configure a device, then explicitly connect to start polling. Addresses are zero-based. TCP uses ordinary sockets. RTU uses an exclusively assigned RS485 port at 9600 8N1. No register writes or automatic discovery.
        </p>
        <p :if={@message} role="alert">{@message}</p>
        <p :if={@devices == :unavailable} role="alert">
          Plugin status unavailable. Refresh before continuing.
        </p>
        <.form
          for={@form}
          id="modbus-config"
          class="ui-stack"
          phx-change="edit"
          phx-submit="configure"
          phx-target={@myself}
        >
          <label>Device ID<input name="device[id]" value={@form[:id].value} required maxlength="32" /></label>
          <label>Transport<select name="device[transport]">
            <option value="tcp" selected={@form[:transport].value == "tcp"}>TCP</option>
            <option value="rtu" selected={@form[:transport].value == "rtu"}>RTU · RS485</option>
          </select></label>
          <div :if={@form[:transport].value == "rtu"}>
            <label>Assigned RS485 port<select name="device[serial_port]" required>
              <option value="">Select assigned port</option>
              <option
                :for={port <- @ports}
                value={port.id}
                selected={@form[:serial_port].value == port.id}
                disabled={!port.present?}
              >
                {port.id}{if !port.present?, do: " — not detected"}
              </option>
            </select></label>
            <p :if={@ports == []}>
              No enabled RS485 port is assigned to this plugin. Stop it, assign a port under Hardware, then start it again.
            </p>
            <input type="hidden" name="device[authorized]" value="false" />
            <label><input
              type="checkbox"
              name="device[authorized]"
              value="true"
              checked={@form[:authorized].value == "true"}
              required
            />I am authorized to poll this bus and have verified no other master is active.</label>
          </div>
          <label :if={@form[:transport].value != "rtu"}>Host<input
            name="device[host]"
            value={@form[:host].value}
            required
            placeholder="192.168.50.10"
          /></label>
          <label :for={
            {field, label, minimum, maximum} <- [
              {"port", "TCP port", 1, 65535},
              {"unit", "Unit ID", 1, 247},
              {"address", "Zero-based register address", 0, 65535},
              {"count", "Register count", 1, 125},
              {"interval", "Poll interval (ms)", 100, 60000},
              {"timeout", "Request timeout (ms)", 100, 5000}
            ]
          }>
            {label}<input
              name={"device[#{field}]"}
              value={@form[field].value}
              type="number"
              min={minimum}
              max={maximum}
              required
            />
          </label>
          <label>Register table<select name="device[table]">
            <option value="holding" selected={@form[:table].value == "holding"}>
              Holding registers (FC3)
            </option>
            <option value="input" selected={@form[:table].value == "input"}>
              Input registers (FC4)
            </option>
          </select></label>
          <button
            class="ui-button ui-button--primary"
            disabled={@uncertain? or @devices == :unavailable}
          >Save configuration · no connection</button>
        </.form>
        <button class="ui-button ui-button--secondary" phx-click="refresh" phx-target={@myself}>Refresh status</button>
        <article :for={device <- if(is_list(@devices), do: @devices, else: [])}>
          <h3>
            {device.id} · {if device.transport == "rtu",
              do: device.serial_port,
              else: "#{device.host}:#{device.port}"}
          </h3>
          <p>
            Unit {device.unit} · {device.table} · {device.address} + {device.count} · {device.state}
          </p>
          <p :if={device.values != nil}>Values: {Enum.join(device.values, ", ")}</p>
          <p :if={device.read_at}>Last successful read: {device.read_at}</p>
          <p :if={device.error} role="alert">{inspect(device.error)}</p>
          <p :if={device.state == :cleanup_required} role="alert">
            RTU cleanup is unverified. Stop the whole plugin from Plugins and inspect cleanup before restarting; this interrupts all its connections.
          </p>
          <button
            :if={device.state == :disconnected}
            class="ui-button ui-button--primary"
            phx-click="connect"
            phx-value-id={device.id}
            phx-target={@myself}
            disabled={@uncertain?}
          >Connect and poll</button>
          <button
            :if={device.state != :disconnected}
            class="ui-button ui-button--secondary"
            phx-click="disconnect"
            phx-value-id={device.id}
            phx-target={@myself}
            disabled={@uncertain?}
          >Disconnect</button>
        </article>
        <p class="ui-help">
          Configuration is volatile. Restart clears devices and never reconnects automatically. While explicitly connected, yamodbus may reconnect the selected transport; polling is read-only. Disconnect stops both polling and reconnects.
        </p>
      </div>
    </section>
    """
  end

  def handle_event("edit", %{"device" => params}, socket),
    do: {:noreply, assign(socket, :form, to_form(params, as: :device))}

  def handle_event("configure", %{"device" => params}, socket) do
    socket = assign(socket, :form, to_form(params, as: :device))
    command(socket, fn -> ModbusPlugin.configure(params["id"], params) end)
  end

  def handle_event("connect", %{"id" => id}, socket),
    do: command(socket, fn -> ModbusPlugin.connect(id) end)

  def handle_event("disconnect", %{"id" => id}, socket),
    do: command(socket, fn -> ModbusPlugin.disconnect(id) end)

  def handle_event("refresh", _, socket) do
    devices = devices()

    {:noreply,
     assign(socket,
       devices: devices,
       ports: ports(),
       uncertain?: devices == :unavailable,
       message: nil
     )}
  end

  defp command(%{assigns: %{uncertain?: true}} = socket, _), do: {:noreply, socket}

  defp command(socket, fun) do
    result = fun.()

    {:noreply,
     assign(socket,
       devices: devices(),
       ports: ports(),
       message: if(result == :ok, do: nil, else: inspect(result))
     )}
  catch
    :exit, _ ->
      {:noreply,
       assign(socket,
         uncertain?: true,
         message: "Command outcome unknown. Refresh and inspect; no automatic retry."
       )}
  end

  defp ports do
    case ModbusPlugin.ports() do
      {:ok, ports} -> Enum.filter(ports, &(&1.kind == :serial))
      _ -> []
    end
  catch
    :exit, _ -> []
  end

  defp devices do
    ModbusPlugin.status()
  catch
    :exit, _ -> :unavailable
  end
end
