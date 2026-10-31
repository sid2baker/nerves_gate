defmodule WorkbenchWeb.FirmwareLive do
  @moduledoc "Firmware development loop: isolated builds, owned QEMU setup, debugging and results."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import WorkbenchWeb.Components
  alias Scenarios.Runner

  def mount(_, _, socket) do
    if connected?(socket), do: Runner.subscribe()
    {:ok, assign(socket, bench: Runner.snapshot(), confirm_reset: false)}
  end

  def handle_event("build", %{"target" => target}, socket),
    do: command(socket, Workbench.Jobs.build(target))

  def handle_event("prepare_reset", _, socket),
    do: {:noreply, assign(socket, confirm_reset: true, error: nil)}

  def handle_event("cancel_reset", _, socket),
    do: {:noreply, assign(socket, :confirm_reset, false)}

  def handle_event("lifecycle", %{"action" => action}, socket),
    do: command(socket, Runner.lifecycle(action))

  def handle_event("wiring", %{"device" => id, "internet" => internet}, socket),
    do: command(socket, Runner.configure({:put, id, internet}))

  def handle_event("add", %{"device" => %{"id" => id, "internet" => internet}}, socket),
    do: command(socket, Runner.configure({:put, String.trim(id), internet}))

  def handle_event("remove", %{"device" => id}, socket),
    do: command(socket, Runner.configure({:delete, id}))

  def handle_info({:scenarios, bench}, socket), do: {:noreply, assign(socket, :bench, bench)}

  defp command(socket, {:error, message}), do: {:noreply, assign(socket, :error, message)}

  defp command(socket, {:ok, _id}), do: command(socket, :ok)

  defp command(socket, :ok),
    do: {:noreply, assign(socket, bench: Runner.snapshot(), error: nil, confirm_reset: false)}

  def render(assigns) do
    ~H"""
    <main class="ui-main ui-stack bench" id="firmware-page">
      <.page_header
        eyebrow="Develop · firmware"
        title="Build and test firmware"
        description="Build an image, run it on owned QEMU devices, then test or debug. Physical updates are reviewed on the selected device."
      />
      <.develop_navigation section={:firmware} />
      <nav class="dev-filters" aria-label="Firmware workflow">
        <a href="#firmware-build">1. Build</a>
        <a href="#simulator-lifecycle">2. Run on QEMU</a>
        <a href="#lab-devices">3. Test and debug</a>
        <a href="#lab-runs">Results</a>
      </nav>
      <p :for={operation <- @bench[:operations] || []} role="status">
        {operation.id} · {operation.kind} · {operation.outcome}
      </p>
      <.panel title="1. Build firmware" icon="port" id="firmware-build">
        <form id="build-firmware" phx-submit="build" class="ui-actions">
          <select name="target" aria-label="Firmware build target">
            <option value="x86_64">x86_64 · simulated QEMU</option>
            <option value="ec100">EC100 · physical hardware</option>
            <option value="em300">EM300 · physical hardware (SPI NAND, bring-up)</option>
          </select>
          <.button type="submit" disabled={@job.status == :running}>Build firmware</.button>
        </form>
        <p class="ui-help">
          Building never installs or flashes firmware. QEMU builds require stopped/reset simulated devices. Backend admission is authoritative.
        </p>
        <.job :if={@job.kind == "firmware"} job={@job} />
        <p class="ui-help">
          Physical EC100 or EM300 image ready? <.link navigate="/devices" class="ui-text-link">Choose a gateway to review an update</.link>, or <.link
            navigate="/provision"
            class="ui-text-link"
          >provision new hardware over USB</.link>.
        </p>
      </.panel>
      <.notice :if={@bench.blocked} tone="warning" role="alert" id="simulator-blocked">
        A worker or cleanup failed. Fault state is uncertain. Inspect <code>_build/simulator/</code>,
        then {if @bench.lifecycle.status == :unavailable,
          do: "restart mix dev.",
          else: "Reset the devices."}
      </.notice>
      <.panel title="2. Run on QEMU" icon="settings" id="simulator-lifecycle">
        <p role="status" aria-live="polite" id="simulator-phase">{@bench.lifecycle.phase}</p>
        <div :if={@bench.lifecycle.status in [:starting, :stopping]} class="ui-progress"></div>
        <code
          :if={@bench.lifecycle[:output] && @bench.lifecycle.status in [:starting, :failed]}
          class="bench-output"
          id="build-output"
        >{@bench.lifecycle[:output]}</code>
        <div class="ui-actions">
          <.button
            id="start-devices"
            phx-click="lifecycle"
            phx-value-action="start"
            loading={@bench.lifecycle.status == :starting}
            disabled={
              @bench.lifecycle.status != :stopped || @bench.lifecycle.reset_required || @bench.blocked ||
                @job.status == :running
            }
          >Start devices</.button>
          <.button
            id="stop-devices"
            variant="secondary"
            phx-click="lifecycle"
            phx-value-action="stop"
            loading={@bench.lifecycle.status == :stopping}
            disabled={
              @job.status == :running || @bench.lifecycle.status not in [:starting, :ready] ||
                (@bench.lifecycle.status == :ready && (@bench.blocked || held?(@bench)))
            }
          >Stop</.button>
          <.button
            id="reset-devices"
            variant="secondary"
            phx-click="prepare_reset"
            disabled={
              @job.status == :running ||
                @bench.lifecycle.status not in [:stopped, :ready, :failed] || held?(@bench)
            }
          >Reset…</.button>
        </div>
        <p class="ui-help">
          Stop keeps disks; Reset erases them. Device-code changes need Reset, then Start. These controls never act on physical devices.
        </p>
        <.notice :if={@confirm_reset} tone="warning" id="confirm-reset" role="alert">
          <p>Erase every simulated device's disk and enrollment? This cannot be undone.</p>
          <div class="ui-actions">
            <.button id="confirm-reset-devices" phx-click="lifecycle" phx-value-action="reset">Erase all simulated devices</.button>
            <.button variant="quiet" phx-click="cancel_reset">Cancel</.button>
          </div>
        </.notice>
      </.panel>
      <.panel title="Virtual wiring" icon="network" id="simulator-devices">
        <div class="ui-settings-list">
          <div
            :for={config <- @bench.lifecycle.devices}
            class="ui-setting-row bench-device"
            id={"device-#{config.id}"}
          >
            <div>
              <h3>
                <.link :if={config.node} navigate={"/devices/#{config.node}"} class="ui-text-link">{config.id}</.link>
                <span :if={!config.node}>{config.id} · run mix dev.network setup</span>
              </h3><p class="ui-help">{config.node}</p>
            </div>
            <div class="ui-setting-value">
              <.device_kind source={:qemu} />
              <span>{simulated_status(@bench, config.id)}</span>
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
              <.button
                id={"remove-#{config.id}"}
                variant="danger"
                phx-click="remove"
                phx-value-device={config.id}
                disabled={!addable?(@bench) || length(@bench.lifecycle.devices) == 1}
              >Remove</.button>
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
            <option value="lan1">Internet on LAN1</option><option value="lan2">
              Internet on LAN2
            </option>
          </select>
          <.button type="submit" variant="secondary" disabled={!addable?(@bench)}>Add device</.button>
        </form>
        <p class="ui-help">
          Wiring applies at the next Start. Adding or removing devices needs Reset first.
        </p>
      </.panel>
      <.panel title="3. Test and debug" icon="check" id="lab-devices">
        <p class="ui-help">
          Owned simulated devices only. Start the bench above before running scenarios or acquiring manual control.
        </p>
        <.setting_row :for={config <- @bench.lifecycle.devices} label={to_string(config.id)}>
          <.device_kind source={:qemu} />
          <span>{simulated_status(@bench, config.id)}</span>
          <.link :if={config.node} navigate={"/devices/#{config.node}/scenarios"} class="ui-text-link">Run scenarios</.link>
          <.link :if={config.node} navigate={"/devices/#{config.node}/manual"} class="ui-text-link">Debug device</.link>
        </.setting_row>
      </.panel>
      <.panel title="Runs and results" icon="check" id="lab-runs">
        <p :if={@bench.runs == []} class="ui-help">No runs yet. Choose a device above.</p>
        <div :for={run <- @bench.runs} class="ui-setting-row" id={"run-#{run.id}"}>
          <div>
            <strong>Run #{run.id} · {run.selection} · {run.device}</strong>
            <p class="ui-help">{run.phase} · Holds {Enum.join(run.devices, ", ")}</p>
            <ul class="bench-scenarios">
              <li :for={row <- run.rows}>
                <strong>{row.id}</strong>
                ·
                <.status tone={result_tone(row.status)}>{row.status}</.status>
                <pre :if={row.detail != ""} class="ui-bus-data">{row.detail}</pre>
              </li>
            </ul>
          </div>
          <.status tone={result_tone(run.status)}>{run.status}</.status>
        </div>
      </.panel>
      <div class="bench-workspace">
        <.panel title="Action log" description="UTC" icon="clock" id="bench-events">
          <p :if={@bench.events == []} class="ui-help">No actions yet.</p>
          <ol
            class="bench-log"
            id="event-log"
            phx-hook="ScrollToBottom"
            tabindex="0"
            aria-label="Chronological simulator events"
          >
            <li :for={event <- @bench.events} id={"event-#{event.id}"}>
              <time datetime={event.at}>{String.slice(event.at, 11, 8)}</time><span>{event.message}</span>
            </li>
          </ol>
        </.panel>
      </div>
      <p class="ui-help">
        Diagnostics: <code>_build/simulator/</code>. Images: <code>firmware/_build/TARGET_dev/nerves/images/nerves_gate.fw</code>. Rebuilds overwrite that image; physical update review creates an immutable snapshot.
      </p>
    </main>
    """
  end

  defp held?(bench), do: Enum.any?(bench.devices, fn {_, device} -> device.owner != nil end)

  defp addable?(bench),
    do:
      bench.lifecycle.status == :stopped and not bench.lifecycle.prepared and
        not bench.lifecycle.reset_required
end
