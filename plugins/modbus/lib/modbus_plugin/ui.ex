defmodule ModbusPlugin.UI do
  @moduledoc "Plugin-owned drafts and controls; every command runs in a supervised plugin process."
  use Phoenix.LiveComponent
  alias ModbusPlugin.{Command, Config, Server}

  @server_mappings ~s([{"id": "holding0", "table": "holding", "address": 0, "initial": 0},
 {"id": "coil0", "table": "coil", "address": 0, "initial": false}])
  @client_mappings ~s([{"id": "holding0", "table": "holding", "address": 0, "direction": "input"},
 {"id": "holding0_set", "table": "holding", "address": 0, "direction": "output", "feedback": "holding0"},
 {"id": "coil0", "table": "coil", "address": 0, "direction": "input"},
 {"id": "coil0_set", "table": "coil", "address": 0, "direction": "output", "feedback": "coil0"}])

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:status, &status/0)
     |> assign_new(:ports, &ports/0)
     |> assign_new(:message, fn -> nil end)
     |> assign_new(:uncertain?, fn -> false end)
     |> assign_new(:values, fn %{status: status} -> values(status) end)
     |> assign_new(:form, fn -> to_form(defaults("server"), as: :connection) end)}
  end

  defp defaults(role) do
    %{
      "id" => if(role == "server", do: "server1", else: "client1"),
      "role" => role,
      "transport" => "rtu",
      "serial_port" => if(role == "server", do: "ttyS3", else: "ttyS4"),
      "authorized" => "false",
      "speed" => "9600",
      "parity" => "none",
      "stop_bits" => "1",
      "host" => "",
      "port" => "502",
      "unit" => "1",
      "interval" => "500",
      "timeout" => "1000",
      "mappings" => if(role == "server", do: @server_mappings, else: @client_mappings)
    }
  end

  def render(assigns) do
    ~H"""
    <section class="ui-panel" id="modbus-plugin">
      <div class="ui-panel-body">
        <h2>Modbus TCP / RTU</h2>
        <p class="ui-help">
          Saved client and server definitions on the plugin's SD storage. Save never communicates; Start explicitly opens the transport and registers the mapped points as platform inputs and outputs. Stop before saving a change. Addresses are zero-based; holding registers are 0..65535, coils true/false.
        </p>
        <p :if={@message} role="alert">{@message}</p>
        <p :if={@status == :unavailable} role="alert">
          Plugin status unavailable. Refresh before continuing.
        </p>
        <p :if={is_map(@status) and @status.storage != nil} role="alert">
          Saved configuration blocked: {inspect(@status.storage)}. Inspect SD storage; nothing is rewritten or started automatically.
        </p>
        <.form
          for={@form}
          id="modbus-config"
          class="ui-stack"
          phx-change="edit"
          phx-submit="save"
          phx-target={@myself}
        >
          <label>Connection ID<input
            name="connection[id]"
            value={@form[:id].value}
            required
            maxlength="32"
            pattern="[a-z][a-z0-9_]*"
          /></label>
          <label>Role<select name="connection[role]">
            <option value="server" selected={@form[:role].value == "server"}>
              Server · exposes a local map
            </option>
            <option value="client" selected={@form[:role].value == "client"}>
              Client · polls and writes a remote device
            </option>
          </select></label>
          <label>Transport<select name="connection[transport]">
            <option value="rtu" selected={@form[:transport].value == "rtu"}>RTU · RS485</option>
            <option value="tcp" selected={@form[:transport].value == "tcp"}>TCP</option>
          </select></label>
          <div :if={@form[:transport].value == "rtu"}>
            <label>Assigned RS485 port<select name="connection[serial_port]" required>
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
            <label>Speed<select name="connection[speed]">
              <option
                :for={speed <- Config.speeds()}
                value={speed}
                selected={@form[:speed].value == to_string(speed)}
              >
                {speed}
              </option>
            </select></label>
            <label>Parity<select name="connection[parity]">
              <option
                :for={parity <- ["none", "even", "odd"]}
                value={parity}
                selected={@form[:parity].value == parity}
              >
                {parity}
              </option>
            </select></label>
            <label>Stop bits<select name="connection[stop_bits]">
              <option
                :for={bits <- ["1", "2"]}
                value={bits}
                selected={@form[:stop_bits].value == bits}
              >
                {bits}
              </option>
            </select></label>
            <input type="hidden" name="connection[authorized]" value="false" />
            <label><input
              type="checkbox"
              name="connection[authorized]"
              value="true"
              checked={@form[:authorized].value == "true"}
              required
            />I am authorized to use this bus and have verified its other devices.</label>
          </div>
          <label :if={@form[:transport].value == "tcp" and @form[:role].value == "client"}>Host<input
            name="connection[host]"
            value={@form[:host].value}
            required
            placeholder="192.168.50.10"
          /></label>
          <label :if={@form[:transport].value == "tcp"}>
            {if @form[:role].value == "server", do: "Listen port", else: "TCP port"}<input
              name="connection[port]"
              value={@form[:port].value}
              type="number"
              min="1"
              max="65535"
              required
            />
          </label>
          <label>Unit ID<input
            name="connection[unit]"
            value={@form[:unit].value}
            type="number"
            min="1"
            max="247"
            required
          /></label>
          <label :if={@form[:role].value == "client"}>Poll interval (ms)<input
            name="connection[interval]"
            value={@form[:interval].value}
            type="number"
            min="100"
            max="60000"
            required
          /></label>
          <label>Request timeout (ms)<input
            name="connection[timeout]"
            value={@form[:timeout].value}
            type="number"
            min="100"
            max="5000"
            required
          /></label>
          <label>
            Mappings (JSON, zero-based addresses){if @form[:role].value == "server",
              do: " · id, table holding|coil, address, initial",
              else:
                " · id, table holding|coil, address, direction input|output, optional feedback input id"}
            <textarea name="connection[mappings]" rows="6" required>{@form[:mappings].value}</textarea>
          </label>
          <button
            class="ui-button ui-button--primary"
            disabled={@uncertain? or @status == :unavailable}
          >Save definition · no connection</button>
        </.form>
        <button class="ui-button ui-button--secondary" phx-click="refresh" phx-target={@myself}>Refresh status</button>
        <article :for={connection <- connections(@status)} id={"modbus-#{connection.id}"}>
          <h3>
            {connection.id} · {connection.role} · {if connection.transport == "rtu",
              do:
                "#{connection.serial_port} #{connection.speed} 8#{String.first(Atom.to_string(connection.parity)) |> String.upcase()}#{connection.stop_bits}",
              else: "#{connection.host || "listen"}:#{connection.port}"} · unit {connection.unit} · {connection.state}
          </h3>
          <p :if={connection.read_at}>Last successful read: {connection.read_at}</p>
          <p :if={connection.error} role="alert">{inspect(connection.error)}</p>
          <p :if={connection.state == :cleanup_required} role="alert">
            RTU cleanup is unverified. Stop the whole plugin from Plugins and inspect cleanup before restarting; this interrupts all its connections.
          </p>
          <ul>
            <li :for={mapping <- connection.mappings}>
              <code>modbus_plugin.{connection.id}.{mapping.id}</code>
              · {mapping.table} {mapping.address} · {mapping.direction}
              <span :if={connection.values != nil and Map.has_key?(connection.values, mapping.id)}>
                · value {inspect(connection.values[mapping.id])}
              </span>
              <span :if={
                mapping.direction == :output and
                  @values["modbus_plugin.#{connection.id}.#{mapping.id}"]
              }>
                · {inspect(@values["modbus_plugin.#{connection.id}.#{mapping.id}"])}
              </span>
              <form
                :if={connection.state == :serving and mapping.direction == :observed}
                phx-submit="put"
                phx-target={@myself}
              >
                <input type="hidden" name="connection" value={connection.id} />
                <input type="hidden" name="mapping" value={mapping.id} />
                <input
                  name="value"
                  placeholder={if mapping.table == :coil, do: "true | false", else: "0..65535"}
                  required
                />
                <button class="ui-button ui-button--secondary" disabled={@uncertain?}>Set local value</button>
              </form>
              <form
                :if={connection.state == :polling and mapping.direction == :output}
                phx-submit="desire"
                phx-target={@myself}
              >
                <input
                  type="hidden"
                  name="output"
                  value={"modbus_plugin.#{connection.id}.#{mapping.id}"}
                />
                <input
                  name="value"
                  placeholder={if mapping.table == :coil, do: "true | false", else: "0..65535"}
                  required
                />
                <button class="ui-button ui-button--secondary" disabled={@uncertain?}>Set desired</button>
                <button
                  class="ui-button ui-button--secondary"
                  type="button"
                  phx-click="release"
                  phx-value-id={"modbus_plugin.#{connection.id}.#{mapping.id}"}
                  phx-target={@myself}
                  disabled={@uncertain?}
                >Release desire</button>
              </form>
            </li>
          </ul>
          <button
            :if={connection.state == :stopped}
            class="ui-button ui-button--primary"
            phx-click="start"
            phx-value-id={connection.id}
            phx-target={@myself}
            disabled={@uncertain?}
          >Start</button>
          <button
            :if={connection.state == :stopped}
            class="ui-button ui-button--secondary"
            phx-click="load"
            phx-value-id={connection.id}
            phx-target={@myself}
          >Edit</button>
          <button
            :if={connection.state == :stopped}
            class="ui-button ui-button--secondary"
            phx-click="delete"
            phx-value-id={connection.id}
            phx-target={@myself}
            disabled={@uncertain?}
          >Delete definition</button>
          <button
            :if={connection.state != :stopped}
            class="ui-button ui-button--secondary"
            phx-click="stop"
            phx-value-id={connection.id}
            phx-target={@myself}
            disabled={@uncertain?}
          >Stop</button>
        </article>
        <p class="ui-help">
          Plugin restart loads definitions but starts nothing. While started, yamodbus may reconnect the transport; Stop ends polling, serving and reconnects. Desired values are repeatable targets written by the client until feedback or a release; a release never writes. Deleting a definition keeps the platform's endpoint history.
        </p>
      </div>
    </section>
    """
  end

  def handle_event("edit", %{"connection" => params}, socket) do
    previous = socket.assigns.form.params
    role = params["role"]

    params =
      if role != previous["role"] and
           previous["mappings"] in [@server_mappings, @client_mappings, ""],
         do: Map.merge(params, Map.take(defaults(role), ["mappings", "serial_port", "id"])),
         else: params

    {:noreply, assign(socket, :form, to_form(params, as: :connection))}
  end

  def handle_event("save", %{"connection" => params}, socket) do
    socket = assign(socket, :form, to_form(params, as: :connection))

    case JSON.decode(params["mappings"] || "") do
      {:ok, mappings} when is_list(mappings) ->
        command(socket, fn ->
          ModbusPlugin.save(params["id"], Map.put(params, "mappings", mappings))
        end)

      _ ->
        {:noreply, assign(socket, :message, "Mappings must be a JSON list.")}
    end
  end

  def handle_event("load", %{"id" => id}, socket) do
    case Enum.find(connections(socket.assigns.status), &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      connection ->
        params =
          connection
          |> Map.take([
            :id,
            :role,
            :transport,
            :host,
            :port,
            :serial_port,
            :authorized,
            :speed,
            :parity,
            :stop_bits,
            :unit,
            :interval,
            :timeout
          ])
          |> Map.new(fn {key, value} -> {Atom.to_string(key), text(value)} end)
          |> Map.put("mappings", JSON.encode!(Config.params(connection)["mappings"]))

        {:noreply,
         assign(
           socket,
           :form,
           to_form(Map.merge(defaults(params["role"]), params), as: :connection)
         )}
    end
  end

  def handle_event("start", %{"id" => id}, socket),
    do: command(socket, fn -> ModbusPlugin.start(id) end)

  def handle_event("stop", %{"id" => id}, socket),
    do: command(socket, fn -> ModbusPlugin.stop(id) end)

  def handle_event("delete", %{"id" => id}, socket),
    do: command(socket, fn -> ModbusPlugin.delete(id) end)

  def handle_event("put", %{"connection" => id, "mapping" => mapping, "value" => value}, socket),
    do: command(socket, fn -> Server.put(id, mapping, parse(value)) end)

  def handle_event("desire", %{"output" => id, "value" => value}, socket) do
    command(socket, fn ->
      with :ok <- Command.claim(id), do: Command.set(id, parse(value))
    end)
  end

  def handle_event("release", %{"id" => id}, socket),
    do: command(socket, fn -> Command.release(id) end)

  def handle_event("refresh", _, socket) do
    status = status()

    {:noreply,
     assign(socket,
       status: status,
       ports: ports(),
       values: values(status),
       uncertain?: status == :unavailable,
       message: nil
     )}
  end

  defp command(%{assigns: %{uncertain?: true}} = socket, _), do: {:noreply, socket}

  defp command(socket, fun) do
    result = fun.()
    status = status()

    {:noreply,
     assign(socket,
       status: status,
       ports: ports(),
       values: values(status),
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

  defp parse(value) when value in ["true", "false"], do: value == "true"

  defp parse(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> value
    end
  end

  defp text(nil), do: ""
  defp text(value), do: to_string(value)

  defp connections(%{connections: connections}), do: connections
  defp connections(_), do: []

  defp values(status) do
    for connection <- connections(status),
        connection.state == :polling,
        mapping <- connection.mappings,
        mapping.direction == :output,
        id = "modbus_plugin.#{connection.id}.#{mapping.id}",
        {:ok, output} <- [Command.output(id)],
        into: %{},
        do: {id, Map.take(output, [:claimed?, :desired])}
  catch
    :exit, _ -> %{}
  end

  defp ports do
    case ModbusPlugin.ports() do
      {:ok, ports} -> Enum.filter(ports, &(&1.kind == :serial))
      _ -> []
    end
  catch
    :exit, _ -> []
  end

  defp status do
    ModbusPlugin.status()
  catch
    :exit, _ -> :unavailable
  end
end
