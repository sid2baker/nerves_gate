defmodule NervesGateWeb.BusesLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents

  on_mount({NervesGateWeb.Observations, :status})

  def handle_params(%{"id" => id}, _, socket) do
    ports = %{rs485: %{"1" => "ttyS3", "2" => "ttyS4"}, can: %{"1" => "can0", "2" => "can1"}}

    case get_in(ports, [socket.assigns.live_action, id]) do
      nil ->
        {:noreply, push_navigate(socket, to: "/equipment")}

      name ->
        port = Enum.find(socket.assigns.projection.buses.ports, &(&1.name == name))

        params = %{
          "port" => name,
          "enabled" => to_string((port && port.enabled) || false),
          "bitrate" => to_string((port && Map.get(port, :bitrate)) || 125_000)
        }

        {:noreply,
         assign(socket,
           port_name: name,
           title:
             "#{if socket.assigns.live_action == :can do
               "CAN"
             else
               "RS485"
             end} #{id}",
           forms: %{name => config_form(params)},
           modbus:
             modbus_form(%{
               "port" => name,
               "unit" => "1",
               "function" => "3",
               "address" => "0",
               "count" => "1",
               "authorized" => "false"
             })
         )}
    end
  end

  def handle_event(
        "change-config",
        %{"bus" => %{"port" => port} = params},
        %{assigns: %{port_name: port}} = socket
      ) do
    {:noreply, assign(socket, :forms, %{port => config_form(params)})}
  end

  def handle_event(
        "configure",
        %{"bus" => %{"port" => port} = params},
        %{assigns: %{port_name: port}} = socket
      ) do
    reply(socket, NervesGateWeb.Backend.bus_configure(port, params))
  end

  def handle_event("capture", %{"port" => port}, %{assigns: %{port_name: port}} = socket) do
    reply(socket, NervesGateWeb.Backend.bus_capture(port))
  end

  def handle_event(
        "change-modbus",
        %{"modbus" => %{"port" => port} = params},
        %{assigns: %{port_name: port, live_action: :rs485}} = socket
      ) do
    {:noreply, assign(socket, :modbus, modbus_form(params))}
  end

  def handle_event(
        "modbus-read",
        %{"modbus" => %{"port" => port} = params},
        %{assigns: %{port_name: port, live_action: :rs485}} = socket
      ) do
    socket = assign(socket, :modbus, modbus_form(Map.put(params, "authorized", "false")))
    reply(socket, NervesGateWeb.Backend.modbus_read(port, params))
  end

  def handle_event(_, _, socket) do
    reply(socket, {:error, %{message: "This request does not match the selected port."}})
  end

  defp reply(socket, result) do
    socket = clear_flash(socket)

    case result do
      :ok ->
        {:noreply,
         put_flash(socket, :info, "Request accepted. Check the observed state and result below.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  defp config_form(params), do: to_form(params, as: :bus, id: "bus-#{params["port"]}")
  defp modbus_form(params), do: to_form(params, as: :modbus)

  defp timestamp(value),
    do: value |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

  def render(assigns) do
    forms =
      Map.new(assigns.projection.buses.ports, fn port ->
        {port.name,
         Map.get(assigns.forms, port.name) ||
           config_form(%{"port" => port.name, "enabled" => "false", "bitrate" => "125000"})}
      end)

    assigns =
      assign(assigns,
        buses: assigns.projection.buses,
        ports: Enum.filter(assigns.projection.buses.ports, &(&1.name == assigns.port_name)),
        forms: forms
      )

    ~H"""
    <.link navigate="/equipment" class="ui-text-link">Back to Equipment</.link>
    <.page_header title={@title} description={@port_name} />
    <.notice :if={@buses.simulated}>
      Preview mode · simulated buses. Workstation hardware is never opened.
    </.notice>
    <.notice :if={!@buses.available} tone="warning">
      Bus diagnostics are unsupported on this target or unavailable.
    </.notice>
    <.notice :if={@buses.error} tone="warning" role="alert">{@buses.error.message}</.notice>
    <.notice :if={@buses.operation} id="bus-operation" role="status">
      Working: {@buses.operation.kind} on {@buses.operation.port}. Other bus operations are unavailable until it finishes.
    </.notice>
    <.notice tone="warning">
      Verify connectors, wiring and termination before enabling this interface. Only use equipment you are authorized to inspect.
    </.notice>
    <p :if={@live_action == :can} class="ui-help">
      CAN connector mapping and physical traffic still need on-device qualification. No CAN transmission or CAN FD is supported.
      Configuration changes the live kernel interface in listen-only mode, without persistent boot settings or automatic retry. A failed change may leave CAN down.
    </p>
    <p :if={@live_action == :rs485} class="ui-help">
      RS485 enable is permission for this app to open the port, not proof of a connected device; it resets on service restart.
      Only the qualified 9600 8N1 automatic-direction profile is offered. No DE/RTS GPIO is guessed.
    </p>
    <.notice :if={@buses.available && @ports == []} tone="warning">
      This port is not detected.
    </.notice>
    <.panel :for={port <- @ports} title="Interface" icon="port" id={"port-#{port.name}"}>
      <:meta>
        <.status>
          {cond do
            !port.present -> "Not detected"
            !port.enabled -> "Disabled"
            true -> "Enabled"
          end}
        </.status>
      </:meta>
      <.port_details port={port} />
      <.form
        for={@forms[port.name]}
        id={"configure-#{port.name}"}
        class="ui-stack"
        phx-change="change-config"
        phx-submit="configure"
      >
        <input type="hidden" name="bus[port]" value={port.name} />
        <.choice_group field={@forms[port.name][:enabled]} label="Interface state">
          <:option value="false" title="Disabled" />
          <:option value="true" title="Enabled" />
        </.choice_group>
        <.field
          :if={port.transport == "can"}
          field={@forms[port.name][:bitrate]}
          label="CAN bitrate (bit/s)"
          help="10000, 20000, 50000, 100000, 125000, 250000, 500000 or 1000000. Listen-only is always used."
          inputmode="numeric"
        />
        <.button type="submit" disabled={!port.present || @buses.operation != nil}>Apply changes</.button>
      </.form>
      <.button
        id={"capture-#{port.name}"}
        phx-click="capture"
        phx-value-port={port.name}
        disabled={
          !port.present || !port.enabled || @buses.operation != nil ||
            (port.transport == "can" && port.listen_only != true)
        }
      >
        Capture once
      </.button>
      <p class="ui-help">
        Receive only, at most five seconds and {if port.transport == "can",
          do: "200 classic CAN frames",
          else: "4096 raw bytes at 9600 8N1"}.
        Empty results do not prove that equipment is absent or healthy. Visiting this page never starts a capture.
      </p>
    </.panel>
    <.panel
      :if={@live_action == :rs485 && @buses.available && @ports != []}
      title="Modbus RTU read"
      icon="equipment"
      id="modbus-read"
    >
      <.notice tone="warning">
        This sends one request. Another master must not be using the bus. A brief quiet-bus check cannot guarantee exclusive access.
        Read functions can have device-specific side effects; consult its register map. No broadcasts, writes, unit scans or retries.
      </.notice>
      <.form
        for={@modbus}
        id="modbus-form"
        class="ui-stack"
        phx-change="change-modbus"
        phx-submit="modbus-read"
      >
        <div class="ui-field-grid">
          <input type="hidden" name="modbus[port]" value={@port_name} />
          <div class="ui-field">
            <label for="modbus-function">Register function</label>
            <select id="modbus-function" name="modbus[function]">
              <option value="3" selected={@modbus[:function].value == "3"}>
                3 · Holding registers
              </option>
              <option value="4" selected={@modbus[:function].value == "4"}>
                4 · Input registers
              </option>
            </select>
          </div>
          <.field field={@modbus[:unit]} label="Unit (1–247)" inputmode="numeric" />
          <.field
            field={@modbus[:address]}
            label="Start address (zero-based)"
            help="0–65535, not 40001-style register numbers."
            inputmode="numeric"
          />
          <.field field={@modbus[:count]} label="Register count (1–32)" inputmode="numeric" />
        </div>
        <label class="ui-check">
          <input type="hidden" name="modbus[authorized]" value="false" />
          <input
            type="checkbox"
            name="modbus[authorized]"
            value="true"
            checked={@modbus[:authorized].value == "true"}
          />
          <span>I am authorized to read these registers and have ensured there is no other master.</span>
        </label>
        <.button
          type="submit"
          disabled={
            @buses.operation != nil ||
              !Enum.any?(@buses.ports, &(&1.name == @modbus[:port].value && &1.present && &1.enabled))
          }
        >
          Read registers once
        </.button>
      </.form>
    </.panel>
    <.bus_result :if={@buses.result && @buses.result.port == @port_name} result={@buses.result} />
    """
  end

  defp port_details(assigns) do
    ~H"""
    <div :if={@port.transport == "can"} class="ui-stack">
      <p>
        Observed: {@port.state} · bitrate {@port.bitrate || "unknown"} · listen-only {inspect(
          @port.listen_only
        )}
      </p>
      <p class="ui-help">
        Kernel packets RX: {@port.rx_packets || "unknown"} / TX: {@port.tx_packets || "unknown"}.
        Error counters RX: {if @port.errors, do: @port.errors.rx, else: "unknown"} / TX: {if @port.errors,
          do: @port.errors.tx,
          else: "unknown"}.
        Counters are cumulative, not a health verdict.
      </p>
    </div>
    <p :if={@port.transport == "rs485"}>
      {@port.profile}. Device presence does not prove wiring, free ownership or reachability.
    </p>
    """
  end

  defp bus_result(assigns) do
    ~H"""
    <.panel title="Last completed result" icon="info" id="bus-result">
      <p>{@result.kind} · {@result.port} · {timestamp(@result.completed_at)}</p>
      <div
        :if={Map.has_key?(@result.data, :frames)}
        class="ui-bus-data"
        tabindex="0"
        role="region"
        aria-label="Captured CAN frames"
      >
        <p :if={@result.data.frames == []}>No frames observed.</p>
        <table :if={@result.data.frames != []}>
          <thead>
            <tr>
              <th>ID (hex)</th><th>Flags</th><th>Data (hex)</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={frame <- @result.data.frames}>
              <td>{frame.id}</td><td>
                {if frame.extended, do: "EXT", else: "STD"} {if frame.remote, do: "RTR"} {if frame.error,
                  do: "ERR"}
              </td><td><code>{frame.data}</code></td>
            </tr>
          </tbody>
        </table>
      </div>
      <div :if={Map.has_key?(@result.data, :hex)}>
        <p>{@result.data.bytes} raw bytes (hex); not decoded protocol messages.</p>
        <pre class="ui-bus-data">{@result.data.hex}</pre>
      </div>
      <div :if={Map.has_key?(@result.data, :registers)}>
        <p>
          Unit {@result.data.unit} · function {@result.data.function}. Raw unsigned 16-bit values; no scaling or byte-order guesses.
        </p>
        <ul>
          <li :for={{value, index} <- Enum.with_index(@result.data.registers)}>
            Address {@result.data.address + index}: <code>{value}</code>
            (0x{Integer.to_string(value, 16) |> String.pad_leading(4, "0")})
          </li>
        </ul>
      </div>
    </.panel>
    """
  end
end
