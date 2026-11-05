defmodule ModbusPlugin.UI do
  @moduledoc "Plugin-owned drafts and controls; every command runs in a supervised plugin process."
  use Phoenix.LiveComponent
  alias ModbusPlugin.{Codec, Command, Config, Discovery, Profiles, Server}

  @server_mappings ~s([{"id": "holding0", "table": "holding", "address": 0, "initial": 0},
 {"id": "coil0", "table": "coil", "address": 0, "initial": false}])
  @client_mappings ~s([{"id": "holding0", "table": "holding", "address": 0, "access": "read"},
 {"id": "holding0_set", "table": "holding", "address": 0, "access": "write", "feedback": "holding0"},
 {"id": "coil0", "table": "coil", "address": 0, "access": "read"},
 {"id": "coil0_set", "table": "coil", "address": 0, "access": "write", "feedback": "coil0"}])

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
      "serial_port" => "",
      "authorized" => "false",
      "speed" => "9600",
      "parity" => "none",
      "stop_bits" => "1",
      "host" => "",
      "port" => "502",
      "unit" => "1",
      "interval" => "500",
      "max_gap" => "0",
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
          Saved client and server definitions on the plugin's SD storage. Save never communicates; Start explicitly opens the transport and registers the mapped points as platform inputs and outputs. Stop before saving a change. Addresses are zero-based protocol addresses, not register numbers like 30001/40001. All four tables are readable; only coils and holding registers are writable.
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
            <label>RS485 port<select name="connection[serial_port]" required>
              <option value="">Select port</option>
              <option
                :for={port <- @ports}
                value={port.id}
                selected={@form[:serial_port].value == port.id}
                disabled={!port.present?}
              >
                {port.label} ({port.id}) — {assignment_label(port)}
              </option>
            </select></label>
            <p :if={@ports == []}>
              No RS485 hardware is detected on this target.
            </p>
            <p class="ui-help">
              Save the stopped definition first, then use Assign port below it if access is missing. Saving never grants access or opens the bus.
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
          <label :if={@form[:role].value == "client"}>Maximum unmapped gap per batch<input
            name="connection[max_gap]"
            value={@form[:max_gap].value}
            type="number"
            min="0"
            max="100"
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
              do: " · id, table, address, type, initial",
              else:
                " · id, table, address, access read|write, type; optional scale, unit, word_order, bit, length, feedback"}
            <textarea name="connection[mappings]" rows="6" required>{@form[:mappings].value}</textarea>
          </label>
          <button
            class="ui-button ui-button--primary"
            disabled={@uncertain? or @status == :unavailable}
          >Save definition · no connection</button>
        </.form>
        <button
          :if={@form[:role].value == "client"}
          class="ui-button ui-button--secondary"
          phx-click="solis"
          phx-target={@myself}
        >Load Solis hybrid template into draft</button>
        <p class="ui-help">
          Types: bool, u16, s16, u32, s32, float32, ascii. 32-bit word_order: high_first or low_first. ASCII length is in registers. A bool register may select a read-only bit (0..15). Verify templates against your device manual before saving.
        </p>
        <button class="ui-button ui-button--secondary" phx-click="refresh" phx-target={@myself}>Refresh status</button>
        <article :for={connection <- connections(@status)} id={"modbus-#{connection.id}"}>
          <h3>
            {connection.id} · {connection.role} · {if connection.transport == "rtu",
              do:
                "#{connection.serial_port} #{connection.speed} 8#{String.first(Atom.to_string(connection.parity)) |> String.upcase()}#{connection.stop_bits}",
              else: "#{connection.host || "listen"}:#{connection.port}"} · unit {connection.unit} · {connection.state}
          </h3>
          <p
            :if={connection.transport == "rtu" and !assigned?(@ports, connection.serial_port)}
            role="status"
          >
            Saved draft — enabled port assignment is required before Start.
            <.link
              navigate={assignment_path(connection.serial_port)}
              class="ui-button ui-button--secondary"
            >Assign port / enable access</.link>
            This leaves the plugin page and may stop the whole plugin; saved definitions are retained. Return here after assignment.
          </p>
          <p :if={connection.read_at}>Last successful read: {connection.read_at}</p>
          <p :if={connection.error} role="alert">{inspect(connection.error)}</p>
          <p :if={connection.state == :cleanup_required} role="alert">
            RTU cleanup is unverified. Stop the whole plugin from Plugins and inspect cleanup before restarting; this interrupts all its connections.
          </p>
          <ul>
            <li :for={mapping <- connection.mappings}>
              <code>modbus_plugin.{connection.id}.{mapping.id}</code>
              · {mapping.table} {mapping.address} · {access(mapping)} · {mapping.type} {mapping.unit}
              <span :if={connection.values != nil and Map.has_key?(connection.values, mapping.id)}>
                · value {inspect(connection.values[mapping.id])}
              </span>
              <span :if={
                access(mapping) == :write and
                  @values["modbus_plugin.#{connection.id}.#{mapping.id}"]
              }>
                · {inspect(@values["modbus_plugin.#{connection.id}.#{mapping.id}"])}
              </span>
              <form
                :if={connection.state == :serving}
                phx-submit="put"
                phx-target={@myself}
              >
                <input type="hidden" name="connection" value={connection.id} />
                <input type="hidden" name="mapping" value={mapping.id} />
                <input
                  name="value"
                  placeholder={Atom.to_string(Codec.endpoint_type(mapping))}
                  required
                />
                <button class="ui-button ui-button--secondary" disabled={@uncertain?}>Set local value</button>
              </form>
              <form
                :if={connection.state == :polling and access(mapping) == :write}
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
                  placeholder={Atom.to_string(Codec.endpoint_type(mapping))}
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
          <form
            :if={connection.role == :client and connection.state == :stopped}
            phx-submit="discover"
            phx-target={@myself}
            id={"discover-#{connection.id}"}
          >
            <h4>Read-only discovery · separate from saved mappings</h4>
            <p>
              Uses this stopped connection, with no endpoint registration or writes. Reads can still affect counters on some devices; verify the device manual and avoid other bus masters. Results stay in memory until Stop.
            </p>
            <input type="hidden" name="connection_id" value={connection.id} />
            <label>Unit IDs (JSON list, at most 16)<input
              name="units"
              value={"[#{connection.unit}]"}
              required
            /></label>
            <label>Ranges (JSON; table, address, count; at most 4096 addresses)<textarea
              name="ranges"
              rows="3"
            >{~s([{"table":"input","address":0,"count":16}])}</textarea></label>
            <label>Request budget<input
              name="budget"
              type="number"
              value="200"
              min="1"
              max="1000"
              required
            /></label>
            <label>Delay between requests (ms)<input
              name="delay"
              type="number"
              value="50"
              min="0"
              max="5000"
              required
            /></label>
            <label><input name="sunspec" type="checkbox" value="true" />Look for SunSpec model blocks (holding 0, 40000, 50000)</label>
            <button class="ui-button ui-button--secondary" disabled={@uncertain?}>Identify, probe FC01–04 and scan · reads only</button>
          </form>
          <div :if={Map.has_key?(connection, :discovery)} id={"evidence-#{connection.id}"}>
            <h4>Raw discovery evidence</h4>
            <p>
              {connection.discovery.requests}/{connection.discovery.budget} requests; {connection.discovery.remaining} operations remaining. Refresh to update. Stop closes the survey and discards evidence.
            </p>
            <pre>{inspect(connection.discovery.units, pretty: true)}</pre>
            <details :if={Map.get(connection.discovery, :failures, []) != []}>
              <summary>Failed scan ranges ({length(connection.discovery.failures)})</summary>
              <pre>{inspect(connection.discovery.failures, pretty: true, limit: 100)}</pre>
            </details>
            <article :for={found <- connection.discovery.sunspec}>
              <p>SunSpec unit {found.unit} · base {found.base}</p>
              <p :if={Map.get(found, :error)}>{inspect(found.error)}</p>
              <div :for={model <- found.models}>
                <code>Model {model.id} · header {model.address} · length {model.length}</code>
                <button
                  :if={Profiles.sunspec(model) != []}
                  class="ui-button ui-button--secondary"
                  phx-click="sunspec"
                  phx-value-id={connection.id}
                  phx-value-address={model.address}
                  phx-value-unit={found.unit}
                  phx-target={@myself}
                >Common-model strings → draft</button>
              </div>
            </article>
            <p>
              Showing {min(length(connection.discovery.evidence), 256)} of {length(
                connection.discovery.evidence
              )} observations. Values are not device semantics. Promotion changes only the editor draft; choose the right unit, ID and type, stop discovery, then save.
            </p>
            <table>
              <thead>
                <tr>
                  <th>Unit</th><th>Table</th><th>Address</th><th>Raw</th><th>Hex</th><th>
                    Observed UTC
                  </th><th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={evidence <- Enum.take(connection.discovery.evidence, 256)}>
                  <td>{evidence.unit}</td><td>{evidence.table}</td><td>{evidence.address}</td><td>
                    {inspect(evidence.raw)}
                  </td><td>{Map.get(evidence, :hex)}</td><td>{evidence.observed_at}</td>
                  <td>
                    <button
                      class="ui-button ui-button--secondary"
                      phx-click="promote"
                      phx-value-id={connection.id}
                      phx-value-unit={evidence.unit}
                      phx-value-table={evidence.table}
                      phx-value-address={evidence.address}
                      phx-target={@myself}
                    >Promote to draft</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <button
            :if={connection.state == :stopped}
            class="ui-button ui-button--primary"
            phx-click="start"
            phx-value-id={connection.id}
            phx-target={@myself}
            disabled={
              @uncertain? or
                (connection.transport == "rtu" and !assigned?(@ports, connection.serial_port))
            }
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
            :max_gap,
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

  def handle_event("solis", _, socket) do
    params = Map.put(socket.assigns.form.params, "mappings", JSON.encode!(Profiles.solis()))

    {:noreply,
     assign(socket,
       form: to_form(params, as: :connection),
       message:
         "Solis template loaded into draft only. Verify your exact inverter register map before saving."
     )}
  end

  def handle_event("discover", params, socket) do
    with {:ok, units} <- JSON.decode(params["units"] || ""),
         {:ok, ranges} <- JSON.decode(params["ranges"] || ""),
         {budget, ""} <- Integer.parse(params["budget"] || ""),
         {delay, ""} <- Integer.parse(params["delay"] || "") do
      command(socket, fn ->
        ModbusPlugin.discover(params["connection_id"], %{
          "units" => units,
          "ranges" => ranges,
          "budget" => budget,
          "delay" => delay,
          "sunspec" => params["sunspec"] == "true"
        })
      end)
    else
      _ ->
        {:noreply,
         assign(
           socket,
           :message,
           "Discovery requires JSON unit/range lists and integer budget/delay."
         )}
    end
  end

  def handle_event("promote", params, socket) do
    connection = Enum.find(connections(socket.assigns.status), &(&1.id == params["id"]))
    evidence = connection && Map.get(connection, :discovery)

    evidence =
      evidence &&
        Enum.find(
          evidence.evidence,
          &(to_string(&1.unit) == params["unit"] and to_string(&1.table) == params["table"] and
              to_string(&1.address) == params["address"])
        )

    if evidence,
      do: draft(socket, connection, evidence.unit, [Discovery.mapping(evidence)], :append),
      else: {:noreply, socket}
  end

  def handle_event("sunspec", params, socket) do
    connection = Enum.find(connections(socket.assigns.status), &(&1.id == params["id"]))
    found = connection && Map.get(connection, :discovery)

    models =
      if found,
        do:
          for(
            block <- found.sunspec,
            to_string(block.unit) == params["unit"],
            model <- block.models,
            to_string(model.address) == params["address"],
            do: {block.unit, model}
          ),
        else: []

    case models do
      [{unit, model}] -> draft(socket, connection, unit, Profiles.sunspec(model), :replace)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("start", %{"id" => id}, socket),
    do: command(socket, fn -> ModbusPlugin.start(id) end)

  def handle_event("stop", %{"id" => id}, socket),
    do: command(socket, fn -> ModbusPlugin.stop(id) end)

  def handle_event("delete", %{"id" => id}, socket),
    do: command(socket, fn -> ModbusPlugin.delete(id) end)

  def handle_event("put", %{"connection" => id, "mapping" => mapping, "value" => value}, socket),
    do:
      command(socket, fn ->
        Server.put(id, mapping, parse(socket, "modbus_plugin.#{id}.#{mapping}", value))
      end)

  def handle_event("desire", %{"output" => id, "value" => value}, socket) do
    command(socket, fn ->
      with :ok <- Command.claim(id), do: Command.set(id, parse(socket, id, value))
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

  defp draft(socket, connection, unit, mappings, mode) do
    params =
      Config.params(connection)
      |> Map.drop(["mappings", "state", "values", "error", "read_at", "discovery"])

    params = Map.new(params, fn {key, value} -> {key, text(value)} end)
    previous = socket.assigns.form.params

    existing =
      case JSON.decode(previous["mappings"] || "") do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    append? =
      mode == :append and previous["id"] == connection.id and previous["unit"] == to_string(unit)

    mappings = if append?, do: Enum.uniq(existing ++ mappings), else: mappings

    params =
      params |> Map.put("unit", to_string(unit)) |> Map.put("mappings", JSON.encode!(mappings))

    {:noreply,
     assign(socket,
       form: to_form(params, as: :connection),
       message: "Evidence promoted to draft only. Verify its meaning, stop discovery, then save."
     )}
  end

  defp access(mapping), do: Map.get(mapping, :access, :local)

  defp parse(socket, id, value) do
    mapping =
      for connection <- connections(socket.assigns.status),
          mapping <- connection.mappings,
          "modbus_plugin.#{connection.id}.#{mapping.id}" == id,
          do: mapping

    case mapping do
      [mapping] -> Codec.parse(mapping, value)
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
        access(mapping) == :write,
        id = "modbus_plugin.#{connection.id}.#{mapping.id}",
        {:ok, output} <- [Command.output(id)],
        into: %{},
        do: {id, Map.take(output, [:claimed?, :desired])}
  catch
    :exit, _ -> %{}
  end

  defp assignment_label(port) do
    cond do
      !port.present? -> "Not detected"
      port.assigned_plugin == nil -> "Available for assignment"
      port.assigned_plugin != "modbus_plugin" -> "Assigned to #{port.assigned_plugin}"
      !port.enabled? -> "Modbus access disabled"
      true -> "Assigned to Modbus"
    end
  end

  defp assigned?(ports, id),
    do:
      Enum.any?(
        ports,
        &(&1.id == id and &1.present? and &1.enabled? and &1.assigned_plugin == "modbus_plugin")
      )

  defp assignment_path(id), do: "/hardware/#{URI.encode_www_form(id)}?plugin=modbus_plugin"

  defp ports do
    case ModbusPlugin.ports() do
      {:ok, ports} -> Enum.filter(ports, &(&1.kind == :rs485))
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
