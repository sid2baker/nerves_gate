defmodule NervesGateWeb.Simulator.OverviewLive do
  @moduledoc "Simulator lifecycle, configuration, devices, runs and the shared event log."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  alias NervesGate.QemuTests

  def mount(_, _, socket) do
    if connected?(socket), do: QemuTests.subscribe()
    {:ok, assign(socket, bench: QemuTests.snapshot(), error: nil, confirm_reset: false)}
  end

  def handle_event("prepare_reset", _, socket),
    do: {:noreply, assign(socket, confirm_reset: true, error: nil)}

  def handle_event("cancel_reset", _, socket),
    do: {:noreply, assign(socket, :confirm_reset, false)}

  def handle_event("lifecycle", %{"action" => action}, socket),
    do: command(socket, QemuTests.lifecycle(action))

  def handle_event("wiring", %{"device" => id, "internet" => internet}, socket),
    do: command(socket, QemuTests.configure({:put, id, internet}))

  def handle_event("add", %{"device" => %{"id" => id, "internet" => internet}}, socket),
    do: command(socket, QemuTests.configure({:put, String.trim(id), internet}))

  def handle_event("remove", %{"device" => id}, socket),
    do: command(socket, QemuTests.configure({:delete, id}))

  def handle_info({:qemu_tests, bench}, socket), do: {:noreply, assign(socket, :bench, bench)}

  defp command(socket, {:error, message}), do: {:noreply, assign(socket, error: message)}

  defp command(socket, :ok),
    do: {:noreply, assign(socket, bench: QemuTests.snapshot(), error: nil, confirm_reset: false)}

  def render(assigns) do
    ~H"""
    <main class="ui-main ui-stack bench" id="simulator">
      <.page_header
        eyebrow="Development · owned QEMU only"
        title="Device simulator"
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

      <.panel title="Lifecycle" icon="settings" id="simulator-lifecycle">
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

      <.panel title="Devices" icon="network" id="simulator-devices">
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
          CLI: <code>mix test --only cable_loss --device {example_device(@bench)}</code>
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
