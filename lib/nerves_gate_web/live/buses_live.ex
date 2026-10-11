defmodule NervesGateWeb.BusesLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import NervesGateWeb.Layouts, only: [settings_nav: 1]

  on_mount({NervesGateWeb.Observations, :status})

  def mount(_, _, socket) do
    forms =
      Map.new(socket.assigns.projection.buses.ports, fn port ->
        {port.name,
         config_form(%{
           "port" => port.name,
           "enabled" => to_string(port.enabled),
           "bitrate" => to_string(Map.get(port, :bitrate) || 125_000)
         })}
      end)

    {:ok,
     assign(socket,
       forms: forms,
       modbus:
         modbus_form(%{
           "port" => "ttyS3",
           "unit" => "1",
           "function" => "3",
           "address" => "0",
           "count" => "1",
           "authorized" => "false"
         })
     )}
  end

  def handle_event("change-config", %{"bus" => params}, socket) do
    {:noreply, update(socket, :forms, &Map.put(&1, params["port"], config_form(params)))}
  end

  def handle_event("configure", %{"bus" => params}, socket),
    do: reply(socket, NervesGate.bus_configure(params["port"], params))

  def handle_event("capture", %{"port" => port}, socket),
    do: reply(socket, NervesGate.bus_capture(port))

  def handle_event("change-modbus", %{"modbus" => params}, socket),
    do: {:noreply, assign(socket, :modbus, modbus_form(params))}

  def handle_event("modbus-read", %{"modbus" => params}, socket) do
    socket = assign(socket, :modbus, modbus_form(Map.put(params, "authorized", "false")))
    reply(socket, NervesGate.modbus_read(params["port"], params))
  end

  defp reply(socket, result) do
    socket = socket |> clear_flash() |> assign(:projection, NervesGate.status())

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
        settings: assigns.live_action == :bus_settings,
        forms: forms
      )

    ~H"""
    <.page_header
      title={if @settings, do: "Bus settings", else: "CAN and RS485"}
      description="Explicit, bounded diagnostics. No automatic discovery or remote protocol bridge."
    />
    <.settings_nav :if={@settings} current={:buses} />
    <.link :if={!@settings} navigate="/equipment" class="ui-text-link">Back to Equipment</.link>
    <.notice :if={@buses.simulated}>
      Preview mode · simulated buses. Workstation hardware is never opened.
    </.notice>
    <.notice :if={!@buses.available} tone="warning">
      Bus diagnostics are unsupported on this target or unavailable.
    </.notice>
    <.notice :if={Phoenix.Flash.get(@flash, :info)} role="status">
      {Phoenix.Flash.get(@flash, :info)}
    </.notice>
    <.notice :if={Phoenix.Flash.get(@flash, :error)} tone="warning" role="alert">
      {Phoenix.Flash.get(@flash, :error)}
    </.notice>
    <.notice :if={@buses.error} tone="warning" role="alert">{@buses.error.message}</.notice>
    <.notice :if={@buses.operation} id="bus-operation" role="status">
      Working: {@buses.operation.kind} on {@buses.operation.port}. Other bus operations are unavailable until it finishes.
    </.notice>
    <.notice tone="warning">
      Verify connectors, wiring and termination before enabling an interface. Only use equipment you are authorized to inspect.
      CAN connector mapping and physical traffic still need on-device qualification. No CAN transmission or CAN FD is supported.
    </.notice>
    <p :if={@settings} class="ui-help">
      CAN configuration changes the live kernel interface in listen-only mode, without persistent boot settings or automatic retry.
      A failed change may leave CAN down. RS485 enable is permission for this app to open the port, not proof of a connected device;
      it resets on service restart. Only the qualified 9600 8N1 automatic-direction profile is offered. No DE/RTS GPIO is guessed.
    </p>
    <.panel :for={port <- @buses.ports} title={port.name} icon="port" id={"port-#{port.name}"}>
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
        :if={@settings}
        for={@forms[port.name]}
        id={"configure-#{port.name}"}
        phx-change="change-config"
        phx-submit="configure"
      >
        <input type="hidden" name="bus[port]" value={port.name} />
        <.choice_group field={@forms[port.name][:enabled]} label={"#{port.name} enabled"}>
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
        <.button type="submit" disabled={!port.present || @buses.operation != nil}>Apply {port.name}</.button>
      </.form>
      <.button
        :if={!@settings}
        id={"capture-#{port.name}"}
        phx-click="capture"
        phx-value-port={port.name}
        disabled={
          !port.present || !port.enabled || @buses.operation != nil ||
            (port.transport == "can" && port.listen_only != true)
        }
      >
        Capture {port.name}
      </.button>
      <p :if={!@settings} class="ui-help">
        Receive only, at most five seconds and {if port.transport == "can",
          do: "200 classic CAN frames",
          else: "4096 raw bytes at 9600 8N1"}.
        Empty results do not prove that equipment is absent or healthy. Visiting this page never starts a capture.
      </p>
    </.panel>
    <.link
      navigate={if @settings, do: "/equipment/buses", else: "/settings/buses"}
      class="ui-text-link"
    >
      {if @settings, do: "Open bus workspace", else: "Configure interfaces in Settings"}
    </.link>
    <.panel
      :if={!@settings && @buses.available}
      title="Modbus RTU read"
      icon="equipment"
      id="modbus-read"
    >
      <.notice tone="warning">
        This sends one request. Another master must not be using the bus. A brief quiet-bus check cannot guarantee exclusive access.
        Read functions can have device-specific side effects; consult its register map. No broadcasts, writes, unit scans or retries.
      </.notice>
      <.form for={@modbus} id="modbus-form" phx-change="change-modbus" phx-submit="modbus-read">
        <div class="ui-field-grid">
          <div class="ui-field">
            <label for="modbus-port">RS485 port</label>
            <select id="modbus-port" name="modbus[port]">
              <option
                :for={name <- ["ttyS3", "ttyS4"]}
                value={name}
                selected={@modbus[:port].value == name}
              >
                {name}
              </option>
            </select>
          </div>
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
    <.bus_result :if={@buses.result} result={@buses.result} />
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
