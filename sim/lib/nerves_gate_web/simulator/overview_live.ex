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
        description="Configure and start disposable gateways, then test each one on its own page."
      />
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
        <ul :if={@bench.lifecycle.progress != %{}} class="ui-help" id="device-progress">
          <li :for={{id, phase} <- Enum.sort(@bench.lifecycle.progress)}>{id}: {phase}</li>
        </ul>
        <div class="ui-actions">
          <.button
            id="start-devices"
            phx-click="lifecycle"
            phx-value-action="start"
            disabled={
              @bench.lifecycle.status != :stopped || @bench.lifecycle.reset_required ||
                @bench.blocked
            }
          >
            Start devices
          </.button>
          <.button
            id="stop-devices"
            variant="secondary"
            phx-click="lifecycle"
            phx-value-action="stop"
            disabled={
              @bench.lifecycle.status not in [:starting, :ready] ||
                (@bench.lifecycle.status == :ready && (@bench.blocked || held?(@bench)))
            }
          >
            Stop · preserve disks
          </.button>
          <.button
            id="reset-devices"
            variant="secondary"
            phx-click="prepare_reset"
            disabled={@bench.lifecycle.status not in [:stopped, :ready, :failed] || held?(@bench)}
          >
            Reset · erase disks
          </.button>
        </div>
        <p class="ui-help">
          Start builds one shared firmware image and bootstraps every device. Stop is a power-off
          and preserves disks; interrupted startup requires Reset. Device-code changes require Reset and Start.
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

      <.panel
        title="Devices"
        description="Each device runs the release firmware and serves its own gateway UI"
        icon="network"
        id="simulator-devices"
      >
        <div class="ui-settings-list">
          <.setting_row
            :for={config <- @bench.lifecycle.devices}
            label={to_string(config.id)}
            description={"#{config.node} · #{device_state(@bench, config.id)}"}
          >
            <div class="ui-actions" id={"device-#{config.id}"}>
              <.link navigate={"/devices/#{config.id}"} class="ui-text-link">Tests</.link>
              <a
                :if={@bench.devices[config.id]}
                href={@bench.devices[config.id].ui}
                target="_blank"
                rel="noreferrer"
                class="ui-text-link"
              >Gateway UI</a>
              <div class="ui-actions" role="group" aria-label={"#{config.id} Internet wiring"}>
                <.button
                  :for={port <- [:lan1, :lan2]}
                  id={"wiring-#{config.id}-#{port}"}
                  variant="secondary"
                  phx-click="wiring"
                  phx-value-device={config.id}
                  phx-value-internet={port}
                  aria-pressed={to_string(config.internet == port)}
                  disabled={@bench.lifecycle.status != :stopped || @bench.lifecycle.reset_required}
                >Internet on {String.upcase(to_string(port))}</.button>
              </div>
              <.button
                id={"remove-#{config.id}"}
                variant="quiet"
                phx-click="remove"
                phx-value-device={config.id}
                disabled={!addable?(@bench) || length(@bench.lifecycle.devices) == 1}
              >Remove</.button>
            </div>
          </.setting_row>
        </div>
        <form id="add-device" phx-submit="add" class="ui-actions">
          <input
            type="text"
            name="device[id]"
            aria-label="New device name"
            placeholder="gateway_c"
            pattern="[a-z][a-z0-9_]{0,31}"
            required
            disabled={!addable?(@bench)}
          />
          <select name="device[internet]" aria-label="Internet wiring" disabled={!addable?(@bench)}>
            <option value="lan1">Internet on LAN1</option>
            <option value="lan2">Internet on LAN2</option>
          </select>
          <.button type="submit" variant="secondary" disabled={!addable?(@bench)}>Add device</.button>
        </form>
        <p class="ui-help">
          Configuration is saved to the simulator file. Wiring applies at the next Start; scenarios
          move the Internet to LAN1. Adding or removing devices changes their addresses and needs Reset first.
        </p>
      </.panel>

      <div class="bench-workspace">
        <.panel
          title="Runs"
          description="Active runs and the latest 20 completed runs across all devices"
          icon="check"
          id="simulator-runs"
        >
          <p :if={@bench.runs == []} class="ui-help">No runs yet. Open a device to run scenarios.</p>
          <ul class="bench-scenarios" id="runs">
            <li :for={run <- @bench.runs} id={"run-#{run.id}"}>
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
        <.panel
          title="Action log"
          description="Last 100 actions and runner events · oldest first · UTC"
          icon="clock"
          id="bench-events"
        >
          <p :if={@bench.events == []} class="ui-help">No actions yet.</p>
          <ol
            class="bench-log"
            id="event-log"
            phx-hook="ScrollToBottom"
            tabindex="0"
            aria-label="Chronological simulator events"
          >
            <li :for={event <- @bench.events} id={"event-#{event.id}"}>
              <time datetime={event.at}>{String.slice(event.at, 11, 8)}</time>
              <span>{event.message}</span>
            </li>
          </ol>
        </.panel>
      </div>
      <footer class="ui-help">
        <p>
          CLI: <code>mix test.firmware --only cable_loss --device gateway_a</code>
          · gateway UI with code reload: <code>mix dev.ui gateway_a</code>
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
      nil -> to_string(bench.lifecycle.status)
      %{blocked: true} -> "blocked · Reset required"
      %{owner: :manual} -> "manual control"
      %{owner: nil} -> "ready"
      %{owner: run} -> "run ##{run}"
    end
  end

  def result_tone(:passed), do: "good"
  def result_tone(:failed), do: "warning"
  def result_tone(_), do: "neutral"
end
