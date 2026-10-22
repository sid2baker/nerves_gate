defmodule DevWeb.OverviewLive do
  @moduledoc "Simulator lifecycle, configuration, devices, runs and the shared event log."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  alias NervesGateSim.QemuTests

  def mount(_, _, socket) do
    if connected?(socket) do
      QemuTests.subscribe()
      Dev.Discovery.refresh()
      Process.send_after(self(), :workbench, 500)
    end

    {:ok,
     assign(socket,
       bench: QemuTests.snapshot(),
       applications: Dev.Applications.list(),
       discovery: Dev.Discovery.snapshot(),
       operation: Dev.Operations.snapshot(),
       error: nil,
       update_address: "",
       confirm_reset: false
     )}
  end

  def handle_event("prepare_reset", _, socket),
    do: {:noreply, assign(socket, confirm_reset: true, error: nil)}

  def handle_event("cancel_reset", _, socket),
    do: {:noreply, assign(socket, :confirm_reset, false)}

  def handle_event("lifecycle", %{"action" => action}, socket),
    do: command(socket, Dev.Workbench.lifecycle(action))

  def handle_event("wiring", %{"device" => id, "internet" => internet}, socket),
    do: command(socket, QemuTests.configure({:put, id, internet}))

  def handle_event("add", %{"device" => %{"id" => id, "internet" => internet}}, socket),
    do: command(socket, QemuTests.configure({:put, String.trim(id), internet}))

  def handle_event("remove", %{"device" => id}, socket),
    do: command(socket, QemuTests.configure({:delete, id}))

  def handle_event("discover", _, socket), do: command(socket, Dev.Discovery.refresh())

  def handle_event("add_address", %{"address" => address}, socket),
    do: command(socket, Dev.Discovery.add(address))

  def handle_event(action, %{"application" => %{"path" => path}}, socket)
      when action in ["create_application", "open_application"] do
    kind = if action == "create_application", do: "new", else: "open"

    case Dev.Workbench.application(kind, path) do
      {:ok, _} -> command(socket, :ok)
      error -> command(socket, error)
    end
  end

  def handle_event("select_update", %{"address" => address}, socket),
    do: {:noreply, assign(socket, update_address: address, error: nil)}

  def handle_event("review_firmware", params, socket),
    do: command(socket, Dev.Workbench.review_firmware(params))

  def handle_event("confirm_firmware", params, socket),
    do: command(socket, Dev.Workbench.confirm_firmware(params["review_id"], params["address"]))

  def handle_event("operation", params, socket),
    do: command(socket, Dev.Workbench.operate(params["kind"], params["app"], params["device"]))

  def handle_info(:workbench, socket) do
    Process.send_after(self(), :workbench, 500)

    {:noreply,
     assign(socket,
       applications: Dev.Applications.list(),
       discovery: Dev.Discovery.snapshot(),
       operation: Dev.Operations.snapshot()
     )}
  end

  def handle_info({:qemu_tests, bench}, socket), do: {:noreply, assign(socket, :bench, bench)}

  defp command(socket, {:error, message}), do: {:noreply, assign(socket, error: message)}

  defp command(socket, :ok),
    do:
      {:noreply,
       assign(socket,
         bench: QemuTests.snapshot(),
         applications: Dev.Applications.list(),
         discovery: Dev.Discovery.snapshot(),
         error: nil,
         confirm_reset: false
       )}

  def render(assigns) do
    ~H"""
    <main class="ui-main ui-stack bench" id="simulator">
      <.page_header
        eyebrow="Devices and applications"
        title="Developer platform"
      >
        <:actions><.theme_toggle /></:actions>
      </.page_header>
      <div class="ui-disconnected">
        <.notice tone="warning" role="alert">
          Connection to the simulator lost. Observations may be stale; connections and faults remain active.
        </.notice>
      </div>
      <.notice :if={@error} tone="warning" role="alert" id="simulator-error">{@error}</.notice>
      <.notice :if={@bench.blocked} tone="warning" role="alert" id="simulator-blocked">
        A worker or cleanup failed. Fault state is uncertain. Inspect <code>_build/qemu-tests/</code>, then {if @bench.lifecycle.status ==
                                                                                                                  :unavailable,
                                                                                                                do:
                                                                                                                  "restart mix dev.",
                                                                                                                else:
                                                                                                                  "Reset the devices."}
      </.notice>

      <.panel title="Devices on this network" icon="network" id="network-devices">
        <div class="ui-actions">
          <.button phx-click="discover" disabled={@discovery.status == :searching}>Refresh discovery</.button>
          <span role="status">{@discovery.status}</span>
        </div>
        <.notice :if={@discovery.error} tone="warning">{@discovery.error}</.notice>
        <p :if={@discovery.devices == []} class="ui-help">No Nerves Gate advertisements found yet.</p>
        <div :for={device <- @discovery.devices} class="ui-setting-row">
          <div>
            <h3>{device.name || device.address}</h3>
            <p>{device.address} · {device.target} · {device.version} · {device.source}</p>
          </div>
          <div class="ui-actions">
            <.button href={device.url} target="_blank" rel="noreferrer" variant="secondary">Open gateway</.button>
            <.button phx-click="select_update" phx-value-address={device.address} variant="secondary">Update firmware…</.button>
          </div>
        </div>
        <form id="add-address" phx-submit="add_address" class="ui-actions">
          <input
            type="text"
            name="address"
            aria-label="Device hostname or IPv4 address"
            placeholder="ec100.example.ts.net or 192.168.1.42"
            required
          />
          <.button type="submit" variant="secondary">Add address</.button>
        </form>
        <p class="ui-help">
          Discovery uses local mDNS, not a subnet scan or VPN configuration. Advertisements are unverified. Add DNS names (including Tailscale names) or IPv4 addresses manually. Only open gateways on trusted networks.
        </p>
      </.panel>
      <.panel title="Physical-device firmware update" icon="settings" id="firmware-update">
        <p class="ui-help">
          Uses the device's standard SSH A/B updater, not disk flashing or factory reset. Review is read-only on the device. Updating writes firmware and reboots it. Use an authorized SSH key; the host key must already be verified in ~/.ssh/known_hosts. An active ssh-agent must hold your key; otherwise standard ~/.ssh key files are used. Password prompts are not available.
        </p>
        <form id="review-firmware" phx-submit="review_firmware" class="ui-stack">
          <input
            type="text"
            name="address"
            value={@update_address}
            aria-label="Firmware device hostname or address"
            placeholder="ec100.example.ts.net"
            required
          />
          <input
            type="number"
            name="port"
            value="22"
            min="1"
            max="65535"
            aria-label="SSH port"
            required
          />
          <input
            type="text"
            name="firmware"
            aria-label="Firmware file path"
            placeholder="firmware/_build/ec100_dev/nerves/images/nerves_gate.fw"
            required
          />
          <.button type="submit" disabled={@operation.status == :running}>Review firmware and device</.button>
        </form>
        <.notice :if={@operation.review} tone="warning" id="firmware-confirmation">
          <p>
            Update {@operation.review.address}:{@operation.review.port} · {@operation.review.target}
          </p>
          <p>
            {@operation.review.current_version} → {@operation.review.version} · serial {@operation.review.serial}
          </p>
          <p>{@operation.review.firmware}</p>
          <code>SHA-256: {@operation.review.sha256}</code>
          <p>
            Review expires after ten minutes. Keep power connected. Type the exact reviewed hostname/address to authorize this update and reboot.
          </p>
          <form phx-submit="confirm_firmware">
            <input type="hidden" name="review_id" value={@operation.review.token} />
            <input
              type="text"
              name="address"
              aria-label="Confirm update hostname or address"
              autocomplete="off"
              required
            />
            <.button type="submit" variant="danger">Update firmware and reboot</.button>
          </form>
        </.notice>
      </.panel>
      <.panel title="Applications" icon="settings" id="applications">
        <p class="ui-help">
          Create an ordinary SDK application or open an existing Mix project. No solution or workspace is required. App directories remain outside the platform source; opened apps are remembered for this session.
        </p>
        <form id="create-application" phx-submit="create_application" class="ui-actions">
          <input
            type="text"
            name="application[path]"
            aria-label="New application directory"
            placeholder="../my_controller"
            required
          />
          <.button type="submit">Create application</.button>
        </form>
        <form id="open-application" phx-submit="open_application" class="ui-actions">
          <input
            type="text"
            name="application[path]"
            aria-label="Existing application directory"
            placeholder="/home/me/projects/my_controller"
            required
          />
          <.button type="submit" variant="secondary">Open application</.button>
        </form>
        <div
          :for={app <- @applications}
          class="ui-setting-row"
          id={"app-#{Base.url_encode64(app.path, padding: false)}"}
        >
          <div>
            <h3>{app.name}</h3><p class="ui-help">{app.path}</p>
          </div>
          <div class="ui-actions">
            <.button
              :for={kind <- ["test", "package"]}
              phx-click="operation"
              phx-value-kind={kind}
              phx-value-app={app.path}
              disabled={@operation.status == :running}
            >{String.capitalize(kind)}</.button>
            <form phx-submit="operation">
              <input type="hidden" name="kind" value="install" />
              <input type="hidden" name="app" value={app.path} />
              <select name="device" aria-label={"Install #{app.name} on simulated device"}>
                <option :for={device <- @bench.lifecycle.devices} value={device.id}>
                  {device.id}
                </option>
              </select>
              <.button
                type="submit"
                disabled={@operation.status == :running || @bench.lifecycle.status != :ready}
              >Install on simulator</.button>
            </form>
          </div>
        </div>
      </.panel>
      <.panel title="Builds and applications" icon="settings" id="workbench-operation">
        <form phx-submit="operation" class="ui-actions">
          <input type="hidden" name="kind" value="firmware" />
          <select name="app" aria-label="Firmware build target">
            <option value="ec100">EC100 physical controller</option>
            <option value="x86_64">x86_64 QEMU</option>
          </select>
          <.button type="submit" disabled={@operation.status == :running}>Build firmware</.button>
        </form>
        <p class="ui-help">
          Building never flashes a device. QEMU builds require stopped/reset simulated devices; EC100 builds do not. Review the resulting .fw file above before authorizing an update.
        </p>
        <p role="status">{@operation.kind} · {@operation.status}</p>
        <code :if={@operation.output} class="bench-output">{@operation.output}</code>
        <p :if={@operation.result}>{@operation.result}</p>
      </.panel>
      <.panel title="Simulator lifecycle" icon="settings" id="simulator-lifecycle">
        <p role="status" aria-live="polite" id="simulator-phase">{@bench.lifecycle.phase}</p>
        <div :if={@bench.lifecycle.status in [:starting, :stopping]} class="ui-progress"></div>
        <code
          :if={@bench.lifecycle[:output] && @bench.lifecycle.status in [:starting, :failed]}
          class="bench-output"
          id="build-output"
          title={@bench.lifecycle[:output]}
        >{@bench.lifecycle[:output]}</code>
        <div class="ui-actions">
          <.button
            id="start-devices"
            phx-click="lifecycle"
            phx-value-action="start"
            loading={@bench.lifecycle.status == :starting}
            disabled={
              @bench.lifecycle.status != :stopped || @bench.lifecycle.reset_required ||
                @bench.blocked
            }
          >
            {if @bench.lifecycle.status == :starting, do: "Starting…", else: "Start devices"}
          </.button>
          <.button
            id="stop-devices"
            variant="secondary"
            phx-click="lifecycle"
            phx-value-action="stop"
            loading={@bench.lifecycle.status == :stopping}
            disabled={
              @bench.lifecycle.status not in [:starting, :ready] ||
                (@bench.lifecycle.status == :ready && (@bench.blocked || held?(@bench)))
            }
          >
            {if @bench.lifecycle.status == :stopping, do: "Stopping…", else: "Stop"}
          </.button>
          <.button
            id="reset-devices"
            variant="secondary"
            phx-click="prepare_reset"
            disabled={@bench.lifecycle.status not in [:stopped, :ready, :failed] || held?(@bench)}
          >
            Reset…
          </.button>
        </div>
        <p class="ui-help">
          Stop keeps disks; Reset erases them. Device-code changes need Reset, then Start.
        </p>
        <.notice :if={@confirm_reset} tone="warning" id="confirm-reset" role="alert">
          <p>Erase every device's disk and enrollment? This cannot be undone.</p>
          <div class="ui-actions">
            <.button id="confirm-reset-devices" phx-click="lifecycle" phx-value-action="reset">
              Erase all devices
            </.button>
            <.button variant="quiet" phx-click="cancel_reset">Cancel</.button>
          </div>
        </.notice>
      </.panel>

      <.panel title="Simulated devices" icon="network" id="simulator-devices">
        <div class="ui-settings-list">
          <div
            :for={config <- @bench.lifecycle.devices}
            :key={config.id}
            class="ui-setting-row bench-device"
            id={"device-#{config.id}"}
          >
            <div>
              <h3>
                <.link navigate={"/devices/#{config.id}"}>{config.id}</.link>
              </h3>
              <p class="ui-muted">{config.node}</p>
            </div>
            <div class="ui-setting-value">
              <.status tone={device_tone(@bench, config.id)}>
                {device_state(@bench, config.id)}
              </.status>
              <span class="ui-help" id={"wiring-label-#{config.id}"}>Internet</span>
              <div class="ui-segmented" role="group" aria-labelledby={"wiring-label-#{config.id}"}>
                <.button
                  :for={port <- [:lan1, :lan2]}
                  id={"wiring-#{config.id}-#{port}"}
                  variant="secondary"
                  phx-click="wiring"
                  phx-value-device={config.id}
                  phx-value-internet={port}
                  aria-pressed={to_string(config.internet == port)}
                  disabled={@bench.lifecycle.status != :stopped || @bench.lifecycle.reset_required}
                >{port_label(port)}</.button>
              </div>
              <.menu id={"device-menu-#{config.id}"} label={"#{config.id} actions"}>
                <.button
                  :if={@bench.devices[config.id]}
                  href={@bench.devices[config.id].ui}
                  target="_blank"
                  rel="noreferrer"
                  variant="quiet"
                  icon="external"
                >Gateway UI</.button>
                <.button
                  id={"remove-#{config.id}"}
                  variant="danger"
                  phx-click="remove"
                  phx-value-device={config.id}
                  disabled={!addable?(@bench) || length(@bench.lifecycle.devices) == 1}
                >Remove</.button>
              </.menu>
            </div>
          </div>
        </div>
        <form id="add-device" phx-submit="add" class="bench-add">
          <input
            type="text"
            name="device[id]"
            aria-label="New device name"
            placeholder="New device, e.g. gateway_c"
            pattern="[a-z][a-z0-9_]{0,31}"
            title="Lowercase letters, digits and underscores, starting with a letter"
            required
            autocomplete="off"
            disabled={!addable?(@bench)}
          />
          <select name="device[internet]" aria-label="Internet port" disabled={!addable?(@bench)}>
            <option value="lan1">Internet on {port_label(:lan1)}</option>
            <option value="lan2">Internet on {port_label(:lan2)}</option>
          </select>
          <.button type="submit" variant="secondary" disabled={!addable?(@bench)}>Add device</.button>
        </form>
        <p class="ui-help">
          Wiring applies at the next Start. Adding or removing devices needs Reset first.
        </p>
      </.panel>

      <div class="bench-workspace">
        <.panel title="Runs" icon="check" id="simulator-runs">
          <p :if={@bench.runs == []} class="ui-help">No runs yet.</p>
          <ul class="bench-scenarios" id="runs">
            <li :for={run <- @bench.runs} :key={run.id} id={"run-#{run.id}"}>
              <div class="bench-scenario-heading">
                <div>
                  <h3>Run #{run.id} · {run.selection}</h3>
                  <p class="ui-help">
                    <.link navigate={"/devices/#{run.device}"} class="ui-text-link">{run.device}</.link>
                    <span :if={length(run.devices) > 1}> · holds {Enum.join(run.devices, ", ")}</span>
                  </p>
                </div>
                <.status tone={result_tone(run.status)}>{run.status}</.status>
              </div>
              <p class="ui-help">{run.phase}</p>
            </li>
          </ul>
        </.panel>
        <.panel title="Action log" description="UTC" icon="clock" id="bench-events">
          <p :if={@bench.events == []} class="ui-help">No actions yet.</p>
          <ol
            class="bench-log"
            id="event-log"
            phx-hook="ScrollToBottom"
            tabindex="0"
            aria-label="Chronological simulator events"
          >
            <li :for={event <- @bench.events} :key={event.id} id={"event-#{event.id}"}>
              <time datetime={event.at}>{String.slice(event.at, 11, 8)}</time>
              <span>{event.message}</span>
            </li>
          </ol>
        </.panel>
      </div>
      <footer class="ui-help">
        <p>
          CLI: <code>mix test.qemu --only cable_loss --device {example_device(@bench)}</code>
          · gateway UI with code reload: <code>mix dev.ui {example_device(@bench)}</code>
          · diagnostics: <code>_build/qemu-tests/</code>
        </p>
      </footer>
    </main>
    """
  end

  defp held?(bench), do: Enum.any?(bench.devices, fn {_, device} -> device.owner != nil end)

  defp addable?(bench),
    do:
      bench.lifecycle.status == :stopped and not bench.lifecycle.prepared and
        not bench.lifecycle.reset_required

  defp device_state(bench, id) do
    case bench.devices[id] do
      nil -> bench.lifecycle.progress[id] || String.capitalize(to_string(bench.lifecycle.status))
      %{blocked: true} -> "Blocked · Reset required"
      %{owner: :manual} -> "Manual control"
      %{owner: nil} -> "Ready"
      %{owner: run} -> "Run ##{run}"
    end
  end

  defp device_tone(bench, id) do
    case bench.devices[id] do
      nil when bench.lifecycle.status in [:starting, :stopping] -> "busy"
      %{blocked: true} -> "warning"
      %{owner: nil} -> "good"
      %{owner: run} when is_integer(run) -> "busy"
      %{manual_action: action} when action != nil -> "busy"
      _ -> "neutral"
    end
  end

  defp example_device(%{lifecycle: %{devices: [config | _]}}), do: config.id
  defp example_device(_), do: "gateway_a"

  def port_label(:lan1), do: "LAN1"
  def port_label(:lan2), do: "LAN2"

  def result_tone(:passed), do: "good"
  def result_tone(:failed), do: "warning"
  def result_tone(:running), do: "busy"
  def result_tone(_), do: "neutral"
end
