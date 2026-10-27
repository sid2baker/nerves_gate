defmodule ModbusPlugin.UI do
  @moduledoc "Plugin-owned drafts and controls; commands run in the supervised controller."
  use Phoenix.LiveComponent

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:devices, &devices/0)
     |> assign_new(:message, fn -> nil end)
     |> assign_new(:uncertain?, fn -> false end)
     |> assign_new(:form, fn ->
       to_form(
         %{
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
        <h2>Modbus TCP</h2>
        <p class="ui-help">
          Read-only holding/input registers using yamodbus. Configure a device, then explicitly connect to start polling. Addresses are zero-based. No serial access, register writes or automatic discovery.
        </p>
        <p :if={@message} role="alert">{@message}</p>
        <p :if={@devices == :unavailable} role="alert">
          Plugin status unavailable. Refresh before continuing.
        </p>
        <.form
          for={@form}
          id="modbus-config"
          class="ui-stack"
          phx-submit="configure"
          phx-target={@myself}
        >
          <label>Device ID<input name="device[id]" value={@form[:id].value} required maxlength="32" /></label>
          <label>Host<input
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
          <h3>{device.id} · {device.host}:{device.port}</h3>
          <p>
            Unit {device.unit} · {device.table} · {device.address} + {device.count} · {device.state}
          </p>
          <p :if={device.values != nil}>Values: {Enum.join(device.values, ", ")}</p>
          <p :if={device.read_at}>Last successful read: {device.read_at}</p>
          <p :if={device.error} role="alert">{inspect(device.error)}</p>
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
          Configuration is volatile. Restart clears devices and never reconnects automatically. While explicitly connected, yamodbus may reconnect the TCP transport; polling is read-only. Disconnect stops both polling and reconnects.
        </p>
      </div>
    </section>
    """
  end

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
     assign(socket, devices: devices, uncertain?: devices == :unavailable, message: nil)}
  end

  defp command(%{assigns: %{uncertain?: true}} = socket, _), do: {:noreply, socket}

  defp command(socket, fun) do
    result = fun.()

    {:noreply,
     assign(socket,
       devices: devices(),
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

  defp devices do
    ModbusPlugin.status()
  catch
    :exit, _ -> :unavailable
  end
end
