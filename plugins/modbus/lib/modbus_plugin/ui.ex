defmodule ModbusPlugin.UI do
  @moduledoc "Transport setup and raw observations. No equipment models or platform output claims."
  use Phoenix.LiveComponent
  alias ModbusPlugin.{Config, Protocol, Server}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:draft, &defaults/0)
     |> assign_new(:status, &status/0)
     |> assign_new(:ports, &ports/0)
     |> assign_new(:message, fn -> nil end)
     |> assign_new(:uncertain?, fn -> false end)}
  end

  defp defaults do
    %{
      "id" => "client1",
      "role" => "client",
      "transport" => "tcp",
      "host" => "",
      "port" => "502",
      "unit" => "1",
      "interval" => "1000",
      "timeout" => "1000",
      "serial_port" => "",
      "speed" => "9600",
      "parity" => "none",
      "stop_bits" => "1",
      "authorized" => "false",
      "ranges" => [blank_range(1)]
    }
  end

  defp blank_range(n),
    do: %{
      "id" => "block#{n}",
      "table" => "input",
      "address" => "0",
      "count" => "1",
      "writable" => "false",
      "initial" => ""
    }

  def render(assigns) do
    ~H"""
    <section id={@id} class="ui-panel">
      <div class="ui-panel-body">
        <h2>Modbus TCP / RTU</h2>
        <p>
          Connect and read raw coils or 16-bit registers. Device interpretation belongs to the consuming integration. Save needs SD storage and never connects; Start is explicit.
        </p>
        <p :if={@message} role="alert">{@message}</p>
        <p :if={@status == :unavailable} role="alert">
          Plugin unavailable. Refresh before issuing another command.
        </p>
        <p :if={is_map(@status) and @status.storage} role="alert">
          Storage: {inspect(@status.storage)}
        </p>
        <h3>Connection draft</h3>
        <form phx-change="edit" phx-submit="save" phx-target={@myself}>
          <label>Connection ID<input name="connection[id]" value={@draft["id"]} required /></label>
          <label>Role<select name="connection[role]">
            <option value="client" selected={@draft["role"] == "client"}>
              Client · poll another device
            </option>
            <option value="server" selected={@draft["role"] == "server"}>
              Server · expose a raw map
            </option>
          </select></label>
          <label>Transport<select name="connection[transport]">
            <option value="tcp" selected={@draft["transport"] == "tcp"}>TCP</option>
            <option value="rtu" selected={@draft["transport"] == "rtu"}>RTU / RS485</option>
          </select></label>
          <div :if={@draft["transport"] == "tcp"}>
            <label :if={@draft["role"] == "client"}>Device IP / hostname<input
              name="connection[host]"
              value={@draft["host"]}
              required
            /></label>
            <label>TCP port<input
              name="connection[port]"
              type="number"
              value={@draft["port"]}
              min="1"
              max="65535"
              required
            /></label>
            <p :if={@draft["role"] == "server"}>
              Listens on all network interfaces. Use only a trusted network.
            </p>
          </div>
          <div :if={@draft["transport"] == "rtu"}>
            <label>RS485 port<select name="connection[serial_port]">
              <option value="">Choose a port</option>
              <option
                :for={port <- @ports}
                value={port.id}
                selected={@draft["serial_port"] == port.id}
              >
                {port.label}
              </option>
            </select></label>
            <p>
              Save first, then use Assign port on the saved connection if needed. Saving grants no hardware access.
            </p>
            <label>Speed<select name="connection[speed]">
              <option
                :for={speed <- Config.speeds()}
                value={speed}
                selected={@draft["speed"] == to_string(speed)}
              >
                {speed}
              </option>
            </select></label>
            <label>Parity<select name="connection[parity]">
              <option :for={parity <- ~w(none even odd)} selected={@draft["parity"] == parity}>
                {parity}
              </option>
            </select></label>
            <label>Stop bits<select name="connection[stop_bits]">
              <option :for={bits <- ~w(1 2)} selected={@draft["stop_bits"] == bits}>{bits}</option>
            </select></label>
            <input type="hidden" name="connection[authorized]" value="false" />
            <label><input
              type="checkbox"
              name="connection[authorized]"
              value="true"
              checked={@draft["authorized"] == "true"}
            />I am authorized to use this bus and have checked other devices.</label>
          </div>
          <label>Unit ID<input
            type="number"
            name="connection[unit]"
            value={@draft["unit"]}
            min="1"
            max="247"
            required
          /></label>
          <label :if={@draft["role"] == "client"}>Poll interval (ms)<input
            type="number"
            name="connection[interval]"
            value={@draft["interval"]}
            min="100"
            max="60000"
            required
          /></label>
          <label>Timeout (ms)<input
            type="number"
            name="connection[timeout]"
            value={@draft["timeout"]}
            min="100"
            max="5000"
            required
          /></label>
          <h4>Raw ranges</h4>
          <p>
            Addresses are zero-based numbers sent on the wire. Each range is read in one request; its values stay in address order.
          </p>
          <fieldset
            :for={{range, index} <- Enum.with_index(@draft["ranges"])}
            id={"#{@id}-range-#{index}"}
            style="display: flex; align-items: flex-start; gap: 12px;"
          >
            <div style="flex: 1; min-width: 0;">
              <div class="ui-field" style="display: flex; flex-wrap: wrap; gap: 12px;">
                <label style="flex: 1; min-width: 8rem;">Range ID<input
                  name={"connection[ranges][#{index}][id]"}
                  value={range["id"]}
                  required
                /></label>
                <label style="flex: 1; min-width: 8rem;">Table<select name={"connection[ranges][#{index}][table]"}>
                  <option
                    :for={table <- Protocol.tables()}
                    value={table}
                    selected={range["table"] == to_string(table)}
                  >
                    {table}
                  </option>
                </select></label>
                <label style="flex: 1; min-width: 8rem;">Start address<input
                  name={"connection[ranges][#{index}][address]"}
                  type="number"
                  value={range["address"]}
                  min="0"
                  max="65535"
                  required
                /></label>
                <label style="flex: 1; min-width: 8rem;">Count<input
                  name={"connection[ranges][#{index}][count]"}
                  type="number"
                  value={range["count"]}
                  min="1"
                  max="2000"
                  required
                /></label>
              </div>
              <div :if={@draft["role"] == "client" and range["table"] in ["coil", "holding"]}>
                <input type="hidden" name={"connection[ranges][#{index}][writable]"} value="false" />
                <label><input
                  type="checkbox"
                  name={"connection[ranges][#{index}][writable]"}
                  value="true"
                  checked={range["writable"] == "true"}
                />Allow explicit raw writes</label>
              </div>
              <label :if={@draft["role"] == "server"}>Initial raw values (optional JSON list; otherwise zeros/false)<input
                name={"connection[ranges][#{index}][initial]"}
                value={range["initial"]}
              /></label>
            </div>
            <button
              type="button"
              class="ui-button"
              style="flex: none; margin-left: auto;"
              aria-label={"Remove range #{range["id"]}"}
              phx-click="remove_range"
              phx-value-index={index}
              phx-target={@myself}
            >Remove range</button>
          </fieldset>
          <button type="button" phx-click="add_range" phx-target={@myself}>Add range</button>
          <button
            class="ui-button ui-button--primary"
            disabled={@uncertain? or @status == :unavailable}
          >Save · no connection</button>
        </form>
        <button phx-click="refresh" phx-target={@myself}>Refresh status</button>
        <article :for={connection <- connections(@status)} id={"modbus-#{connection.id}"}>
          <h3>
            {connection.id} · {connection.role} · {if connection.transport == "tcp",
              do: "#{connection.host}:#{connection.port}",
              else: connection.serial_port} · unit {connection.unit} · {connection.state}
          </h3>
          <p :if={connection.error} role="alert">{inspect(connection.error)}</p>
          <a
            :if={connection.transport == "rtu" and not assigned?(@ports, connection.serial_port)}
            href={"/hardware/#{URI.encode_www_form(connection.serial_port)}?plugin=modbus_plugin"}
          >Assign port / enable access</a>
          <div :for={range <- connection.ranges}>
            <code>{range.id} · {range.table} {range.address} · count {range.count}</code>
            <pre>{inspect(if(connection.role == :client, do: Map.get(Map.get(connection, :observations, %{}), range.id), else: Map.get(Map.get(connection, :values, %{}), range.id)), pretty: true)}</pre>
            <form
              :if={
                connection.state == :serving or
                  (connection.state in [:polling, :failed] and Map.get(range, :writable, false))
              }
              phx-submit="raw_write"
              phx-target={@myself}
            >
              <input type="hidden" name="connection" value={connection.id} />
              <input type="hidden" name="range" value={range.id} />
              <input type="hidden" name="role" value={connection.role} />
              <label>Raw values in address order (JSON list)<input
                name="values"
                placeholder="[0, 65535] or [true, false]"
                required
              /></label>
              <button disabled={@uncertain?}>{if connection.role == :server,
                do: "Set local raw values",
                else: "Write once · no retry"}</button>
            </form>
          </div>
          <button phx-click="load" phx-value-id={connection.id} phx-target={@myself}>Edit draft</button>
          <button
            :if={connection.state == :stopped}
            phx-click="start"
            phx-value-id={connection.id}
            phx-target={@myself}
            disabled={@uncertain?}
          >Start</button>
          <button
            :if={connection.state != :stopped}
            phx-click="stop"
            phx-value-id={connection.id}
            phx-target={@myself}
            disabled={@uncertain?}
          >Stop</button>
          <button
            :if={connection.state == :stopped}
            phx-click="delete"
            phx-value-id={connection.id}
            phx-target={@myself}
            disabled={@uncertain?}
          >Delete definition</button>
          <details :if={connection.role == :client and connection.state == :stopped}>
            <summary>Advanced · read-only discovery</summary>
            <p>
              Reads can affect counters and consume shared bus time. Check the device manual first. No writes, automatic range creation or background scans.
            </p>
            <form phx-submit="discover" phx-target={@myself}>
              <input type="hidden" name="connection_id" value={connection.id} />
              <label>Unit IDs (comma-separated)<input name="units" value={connection.unit} required /></label>
              <label>Table<select name="table"><option :for={table <- Protocol.tables()} value={table}>
                {table}
              </option></select></label>
              <label>Start address<input
                type="number"
                name="address"
                value="0"
                min="0"
                max="65535"
                required
              /></label>
              <label>Count<input type="number" name="count" value="16" min="1" max="4096" required /></label>
              <button disabled={@uncertain?}>Start read-only survey</button>
            </form>
          </details>
          <details :if={Map.has_key?(connection, :discovery)} open>
            <summary>Raw discovery results</summary>
            <p>
              {connection.discovery.requests}/{connection.discovery.budget} requests · {connection.discovery.remaining} operations left. Refresh to update; Stop discards results.
            </p>
            <pre>{inspect(connection.discovery.units, pretty: true)}</pre>
            <pre>{inspect(connection.discovery.failures, pretty: true)}</pre>
            <p>Showing up to 256 of {length(connection.discovery.evidence)} observations.</p>
            <pre>{inspect(Enum.take(connection.discovery.evidence, 256), pretty: true, limit: :infinity)}</pre>
          </details>
        </article>
      </div>
    </section>
    """
  end

  def handle_event("edit", %{"connection" => params}, socket),
    do: {:noreply, assign(socket, :draft, merge_draft(socket.assigns.draft, params))}

  def handle_event("add_range", _, socket),
    do:
      {:noreply,
       update(
         socket,
         :draft,
         &Map.update!(&1, "ranges", fn list ->
           n =
             Enum.find(1..(length(list) + 1), fn n ->
               Enum.all?(list, fn range -> range["id"] != "block#{n}" end)
             end)

           list ++ [blank_range(n)]
         end)
       )}

  def handle_event("remove_range", %{"index" => index}, socket),
    do:
      {:noreply,
       update(
         socket,
         :draft,
         &Map.update!(&1, "ranges", fn list -> List.delete_at(list, String.to_integer(index)) end)
       )}

  def handle_event("save", %{"connection" => params}, socket) do
    draft = merge_draft(socket.assigns.draft, params)
    socket = assign(socket, :draft, draft)

    with {:ok, ranges} <- range_params(draft) do
      command(socket, fn -> ModbusPlugin.save(draft["id"], Map.put(draft, "ranges", ranges)) end)
    else
      _ ->
        {:noreply, assign(socket, :message, "Initial values must be a JSON list of raw values.")}
    end
  end

  def handle_event("load", %{"id" => id}, socket) do
    case Enum.find(connections(socket.assigns.status), &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      connection ->
        params = Config.params(connection)

        ranges =
          Enum.map(params["ranges"], fn r ->
            Map.new(r, fn {k, v} ->
              {k, if(k == "initial", do: JSON.encode!(v), else: text(v))}
            end)
          end)

        draft = params |> Map.new(fn {k, v} -> {k, text(v)} end) |> Map.put("ranges", ranges)
        {:noreply, assign(socket, :draft, Map.merge(defaults(), draft))}
    end
  end

  def handle_event("start", %{"id" => id}, socket),
    do: command(socket, fn -> ModbusPlugin.start(id) end)

  def handle_event("stop", %{"id" => id}, socket),
    do: command(socket, fn -> ModbusPlugin.stop(id) end)

  def handle_event("delete", %{"id" => id}, socket),
    do: command(socket, fn -> ModbusPlugin.delete(id) end)

  def handle_event("refresh", _, socket),
    do:
      {:noreply,
       assign(socket, status: status(), ports: ports(), uncertain?: false, message: nil)}

  def handle_event("raw_write", params, socket) do
    case JSON.decode(params["values"] || "") do
      {:ok, values} when is_list(values) ->
        command(socket, fn ->
          if params["role"] == "server",
            do: Server.put(params["connection"], params["range"], values),
            else: ModbusPlugin.write(params["connection"], params["range"], values)
        end)

      _ ->
        {:noreply, assign(socket, :message, "Raw values must be a JSON list.")}
    end
  end

  def handle_event("discover", params, socket) do
    units = params["units"] |> String.split(",") |> Enum.map(&(String.trim(&1) |> integer()))

    command(socket, fn ->
      ModbusPlugin.discover(params["connection_id"], %{
        "units" => units,
        "ranges" => [
          %{
            "table" => params["table"],
            "address" => integer(params["address"]),
            "count" => integer(params["count"])
          }
        ]
      })
    end)
  end

  defp merge_draft(previous, params) do
    params = Map.reject(params, fn {key, _} -> String.starts_with?(key, "_unused_") end)

    ranges =
      case params["ranges"] do
        nil ->
          []

        map when is_map(map) ->
          map |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end) |> Enum.map(&elem(&1, 1))
      end

    Map.merge(previous, Map.put(params, "ranges", ranges))
  end

  defp range_params(draft) do
    Enum.reduce_while(draft["ranges"], {:ok, []}, fn range, {:ok, acc} ->
      common = Map.take(range, ~w(id table address count))

      case draft["role"] do
        "client" ->
          {:cont, {:ok, acc ++ [Map.put(common, "writable", range["writable"] || "false")]}}

        "server" ->
          case JSON.decode(range["initial"] || "") do
            {:ok, values} when is_list(values) ->
              {:cont, {:ok, acc ++ [Map.put(common, "initial", values)]}}

            _ ->
              if range["initial"] in [nil, ""],
                do: {:cont, {:ok, acc ++ [common]}},
                else: {:halt, :error}
          end
      end
    end)
  end

  defp integer(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp text(nil), do: ""
  defp text(value) when is_list(value), do: ""
  defp text(value), do: to_string(value)
  defp command(%{assigns: %{uncertain?: true}} = socket, _), do: {:noreply, socket}

  defp command(socket, fun) do
    result = fun.()

    {:noreply,
     assign(socket,
       status: status(),
       ports: ports(),
       uncertain?: result == {:error, :outcome_unknown},
       message: if(result == :ok, do: nil, else: inspect(result))
     )}
  catch
    :exit, _ ->
      {:noreply,
       assign(socket,
         uncertain?: true,
         message: "Command outcome unknown. Refresh and inspect; never blindly retry a write."
       )}
  end

  defp connections(status) when is_map(status), do: status.connections
  defp connections(_), do: []

  defp assigned?(ports, id),
    do:
      Enum.any?(
        ports,
        &(&1.id == id and &1.present? and &1.enabled? and &1.assigned_plugin == "modbus_plugin")
      )

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
