defmodule NervesGateWeb.BusesLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents

  on_mount({NervesGateWeb.Observations, :status})

  def handle_params(%{"id" => id}, _, socket) do
    ports = %{rs485: %{"1" => "ttyS3", "2" => "ttyS4"}, can: %{"1" => "can0", "2" => "can1"}}

    case get_in(ports, [socket.assigns.live_action, id]) do
      nil ->
        {:noreply, push_navigate(socket, to: "/hardware")}

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
           title: "#{if socket.assigns.live_action == :can, do: "CAN", else: "RS485"} #{id}",
           forms: %{name => config_form(params)}
         )}
    end
  end

  def handle_event(
        "change-config",
        %{"bus" => %{"port" => port} = params},
        %{assigns: %{port_name: port}} = socket
      ),
      do: {:noreply, assign(socket, :forms, %{port => config_form(params)})}

  def handle_event(
        "configure",
        %{"bus" => %{"port" => port} = params},
        %{assigns: %{port_name: port}} = socket
      ),
      do: reply(socket, NervesGate.Buses.configure(port, params))

  def handle_event("capture", %{"port" => port}, %{assigns: %{port_name: port}} = socket),
    do: reply(socket, NervesGate.Buses.capture(port))

  def handle_event(_, _, socket),
    do:
      reply(
        socket,
        {:error, %{message: "This request does not match a hardware diagnostic action."}}
      )

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

  defp timestamp(value),
    do: value |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

  defp in_use?(port), do: Map.get(port, :claimed, false) || Map.get(port, :subscribers, 0) > 0

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
    <.back_link navigate="/hardware">Hardware</.back_link>
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
    <p class="ui-help">
      Applications own equipment protocols, addresses and data collection. The gateway manages access
      to this physical interface. Visiting this page never opens a port or starts traffic.
    </p>
    <.notice tone="warning">
      Verify connectors, wiring and termination before enabling this interface. Only inspect hardware you are authorized to use.
    </.notice>
    <p :if={@live_action == :can} class="ui-help">
      CAN connector mapping and physical traffic still need on-device qualification. No CAN transmission or CAN FD is supported.
      Configuration changes the live kernel interface in listen-only mode, without persistent boot settings or automatic retry. A failed change may leave CAN down.
      Receive subscriptions can be shared; release them before reconfiguring the interface.
    </p>
    <p :if={@live_action == :rs485} class="ui-help">
      Enabling allows applications to claim this port exclusively; it is not proof of connected equipment and resets on service restart.
      Diagnostics cannot use a claimed port. Only the qualified 9600 8N1 automatic-direction profile is offered. No DE/RTS GPIO is guessed.
    </p>
    <.notice :if={@buses.available && @ports == []} tone="warning">
      This port is not detected.
    </.notice>
    <.panel :for={port <- @ports} title="Interface" icon="port" id={"port-#{port.name}"}>
      <:meta>
        <.status>
          {cond do
            !port.present -> "Not detected"
            in_use?(port) -> "In use by applications"
            !port.enabled -> "Disabled"
            true -> "Available"
          end}
        </.status>
      </:meta>
      <.port_details port={port} />
      <.notice :if={in_use?(port)}>
        Applications are using this interface. Release access before changing its configuration.
      </.notice>
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
        <.button type="submit" disabled={!port.present || @buses.operation != nil || in_use?(port)}>Apply changes</.button>
      </.form>
      <.button
        id={"capture-#{port.name}"}
        phx-click="capture"
        phx-value-port={port.name}
        disabled={
          !port.present || !port.enabled || @buses.operation != nil || Map.get(port, :claimed, false) ||
            (port.transport == "can" && port.listen_only != true)
        }
      >
        Capture once
      </.button>
      <p class="ui-help">
        Receive only, at most five seconds and {if port.transport == "can",
          do: "200 classic CAN frames",
          else: "4096 raw bytes at 9600 8N1"}.
        Empty results do not prove that equipment is absent or healthy.
      </p>
    </.panel>
    <.bus_result
      :if={@buses.result && @buses.result.port == @port_name && @buses.result.kind == "capture"}
      result={@buses.result}
    />
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
      <p>Application receive subscriptions: {Map.get(@port, :subscribers, 0)}</p>
    </div>
    <p :if={@port.transport == "rs485"}>
      {@port.profile}. Device presence does not prove wiring, free ownership or reachability.
    </p>
    """
  end

  defp bus_result(assigns) do
    ~H"""
    <.panel title="Last completed capture" icon="info" id="bus-result">
      <p>{@result.port} · {timestamp(@result.completed_at)}</p>
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
              <td>{frame.id}</td>
              <td>
                {if frame.extended, do: "EXT", else: "STD"} {if frame.remote, do: "RTR"} {if frame.error,
                  do: "ERR"}
              </td>
              <td><code>{frame.data}</code></td>
            </tr>
          </tbody>
        </table>
      </div>
      <div :if={Map.has_key?(@result.data, :hex)}>
        <p>{@result.data.bytes} raw bytes (hex); not decoded protocol messages.</p>
        <pre class="ui-bus-data">{@result.data.hex}</pre>
      </div>
    </.panel>
    """
  end
end
