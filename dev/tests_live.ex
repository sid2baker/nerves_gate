defmodule NervesGateWeb.TestsLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  alias NervesGate.{ManualFaults, QemuTests}

  on_mount({NervesGateWeb.Observations, :status})

  def mount(_, _, socket) do
    if connected?(socket), do: QemuTests.subscribe()
    {:ok, assign(socket, run: QemuTests.snapshot(), error: nil, confirm_run: nil)}
  end

  def handle_event("mode", %{"mode" => mode}, socket),
    do: command(socket, QemuTests.mode(mode))

  def handle_event("manual", %{"action" => action}, socket),
    do: command(socket, QemuTests.manual(action))

  def handle_event("prepare_run", %{"scenario" => scenario}, socket),
    do: {:noreply, assign(socket, confirm_run: scenario, error: nil)}

  def handle_event("cancel_run", _, socket),
    do: {:noreply, assign(socket, :confirm_run, nil)}

  def handle_event("run", %{"scenario" => scenario}, socket),
    do: command(socket, QemuTests.run(scenario))

  def handle_info({:qemu_tests, run}, socket), do: {:noreply, assign(socket, :run, run)}

  defp command(socket, {:error, message}), do: {:noreply, assign(socket, error: message)}

  defp command(socket, {:ok, _}), do: command(socket, :ok)

  defp command(socket, :ok),
    do: {:noreply, assign(socket, run: QemuTests.snapshot(), error: nil, confirm_run: nil)}

  def render(assigns) do
    ~H"""
    <main class="ui-main ui-stack bench" id="tests">
      <.link href="/" class="ui-text-link">← Back to Overview</.link>
      <.page_header
        eyebrow="Development · owned QEMU only"
        title="Device test bench"
        description="Run repeatable scenarios or inject a fault and watch the real device respond."
      />
      <div class="ui-disconnected">
        <.notice tone="warning" role="alert">
          Connection to the bench lost. Controls and observations may be stale; connections and faults remain active.
        </.notice>
      </div>
      <.panel
        title="Observed device"
        description="Live device projection, not a test verdict"
        icon="network"
        id="device-summary"
      >
        <div class="bench-summary">
          <div
            :for={item <- summary(@projection)}
            class="bench-observation"
            data-observation={item.id}
          >
            <h3>{item.name}</h3>
            <.status tone={item.tone}>{item.label}</.status>
          </div>
        </div>
        <p :if={@run.faults["vm"]} class="ui-help">
          VM pause is injected. The projection may show its last observation until the connection times out.
        </p>
        <p :if={!@projection.backend.available} class="ui-help">
          Device unavailable; waiting for a fresh projection. Fault controls use the separate QEMU control channel.
        </p>
      </.panel>

      <.panel
        :if={@run.topology}
        title="Bench connections"
        description={if @run.blocked, do: "Last confirmed; current connections unknown"}
        icon="network"
        id="bench-connections"
      >
        <.setting_row :for={port <- [:lan1, :lan2]} label={String.upcase(to_string(port))}>
          <span id={"bench-#{port}-network"}>{network_label(@run.topology[port])}</span>
        </.setting_row>
        <.setting_row label="Management">Local control only · no Internet forwarding</.setting_row>
      </.panel>

      <section class="bench-faults" id="active-faults" aria-label="Injected faults">
        <div>
          <h2>Injected faults</h2>
          <p class="ui-help">These are deliberate disruptions, not observed device failures.</p>
        </div>
        <p :if={@run.blocked} role="alert">
          Unknown — last confirmed faults below. Restart the session.
        </p>
        <p :if={@run.faults == %{} && !@run.blocked} id="no-faults">None active</p>
        <ul :if={@run.faults != %{}} class="bench-fault-list">
          <li :for={{key, label} <- Enum.sort(@run.faults)} id={"fault-#{key}"}>
            <.status tone="warning">{label}</.status>
          </li>
        </ul>
      </section>

      <.notice :if={@error} tone="warning" role="alert" id="bench-error">{@error}</.notice>
      <.notice :if={@run.blocked} tone="warning" role="alert">
        A worker or cleanup failed. Control is blocked because fault state is uncertain.
        Inspect <code>_build/qemu-tests/</code>, then restart <code>mix dev.qemu</code>.
      </.notice>
      <div class="bench-toolbar">
        <div class="ui-actions" role="group" aria-label="Bench control mode">
          <.button
            id="mode-scenarios"
            variant="secondary"
            phx-click="mode"
            phx-value-mode="scenarios"
            aria-pressed={to_string(@run.mode == :scenarios)}
            disabled={busy?(@run)}
          >Scenarios</.button>
          <.button
            id="mode-manual"
            variant="secondary"
            phx-click="mode"
            phx-value-mode="manual"
            aria-pressed={to_string(@run.mode == :manual)}
            disabled={busy?(@run) || @run.mode == :manual}
          >Manual</.button>
        </div>
        <p class="ui-help" id="control-owner">{owner_label(@run)}</p>
      </div>

      <div class="bench-workspace">
        <div class="ui-stack">
          <.panel title="Execution" icon="clock" id="execution">
            <p role="status" aria-live="polite" id="run-status">{@run.phase}</p>
            <div :if={@run.id && @run.mode == :scenarios}>
              <p class="ui-help">
                Run #{@run.id} · {@run.status} · {completed(@run)} / {selected(@run)} scenarios finished
              </p>
              <progress
                class="bench-progress"
                value={completed(@run)}
                max={max(selected(@run), 1)}
                aria-label="Scenario progress"
              />
            </div>
          </.panel>

          <.panel
            :if={@run.mode == :manual}
            title="Manual controls"
            description="Reversible faults only; management networking is never faulted"
            icon="settings"
            id="manual-controls"
          >
            <.notice>
              Manual control is shared by every browser and blocks UI, CLI and CI scenario runs.
              Closing this page does not clear faults. Switching to Scenarios clears them and releases control.
            </.notice>
            <div class="ui-settings-list">
              <.setting_row :for={control <- ManualFaults.controls()} label={control.name}>
                <div class="ui-actions" role="group" aria-label={control.name}>
                  <.button
                    :for={{action, label} <- control.choices}
                    id={"manual-#{action}"}
                    variant="secondary"
                    phx-click="manual"
                    phx-value-action={action}
                    disabled={busy?(@run)}
                  >{label}</.button>
                </div>
              </.setting_row>
            </div>
            <.button
              id="clear-faults"
              phx-click="manual"
              phx-value-action="clear"
              disabled={busy?(@run)}
            >
              Clear all faults
            </.button>
            <p class="ui-help">
              Clear puts Internet on LAN1, reconnects both cables, removes faults and resumes the VM.
              Moving a cable does not change gateway settings. The disk and enrollment are preserved.
              Reboot, power cut and fresh disk are not manual controls.
            </p>
          </.panel>

          <.panel
            :if={@run.mode == :scenarios}
            title="Scenarios"
            description="The same Elixir scenarios in the UI, CLI and CI"
            icon="check"
            id="scenarios"
          >
            <:meta>
              <.button
                id="run-all"
                phx-click="prepare_run"
                phx-value-scenario="all"
                disabled={busy?(@run)}
              >Run all</.button>
            </:meta>
            <p class="ui-help">
              Scenarios change device settings. Fresh-disk scenarios erase enrollment;
              any failed scenario also replaces the disk. Do not edit the device elsewhere during a run.
            </p>
            <.notice :if={@confirm_run} tone="warning" id="confirm-run" role="alert">
              <p>
                Start <strong>{@confirm_run}</strong>? Device settings may change and disk replacement erases Tailscale enrollment.
              </p>
              <div class="ui-actions">
                <.button
                  id="confirm-start"
                  phx-mounted={Phoenix.LiveView.JS.focus()}
                  phx-click="run"
                  phx-value-scenario={@confirm_run}
                  disabled={busy?(@run)}
                >Start run</.button>
                <.button variant="quiet" phx-click="cancel_run">Cancel</.button>
              </div>
            </.notice>
            <ul
              class="bench-scenarios"
              id="test-results"
              tabindex="0"
              aria-label="Available scenarios"
            >
              <li :for={row <- @run.rows} id={"scenario-#{row.id}"}>
                <div class="bench-scenario-heading">
                  <div>
                    <h3>{row.name}</h3>
                    <p class="ui-help">
                      <code>{row.id}</code><span :if={row.fresh_disk} class="bench-destructive"> · fresh disk</span>
                    </p>
                  </div>
                  <.button
                    variant="secondary"
                    phx-click="prepare_run"
                    phx-value-scenario={row.id}
                    disabled={busy?(@run)}
                    aria-label={"Run #{row.id}"}
                  >Run</.button>
                </div>
                <div class="ui-actions">
                  <.status tone={result_tone(row.status)}>{row.status}</.status>
                  <span :if={row.milliseconds} class="ui-help">{duration(row.milliseconds)}</span>
                </div>
                <details :if={row.status == :failed && row.detail != ""}>
                  <summary>Failure details</summary>
                  <pre class="ui-bus-data">{row.detail}</pre>
                </details>
              </li>
            </ul>
          </.panel>
        </div>
        <.panel
          title="Action log"
          description="Last 100 actions and runner events · oldest first · UTC"
          icon="clock"
          id="bench-events"
        >
          <p :if={@run.events == []} class="ui-help">No actions yet. Choose a mode to begin.</p>
          <ol
            class="bench-log"
            id="event-log"
            phx-hook="ScrollToBottom"
            tabindex="0"
            aria-label="Chronological bench events"
          >
            <li :for={event <- @run.events} id={"event-#{event.id}"}>
              <time datetime={event.at}>{String.slice(event.at, 11, 8)}</time>
              <span>{event.message}</span>
            </li>
          </ol>
        </.panel>
      </div>
      <footer class="ui-help">
        <p>
          CLI: <code>mix test --only cable_loss</code>
          · latest run and 100 events kept in memory · diagnostics: <code>_build/qemu-tests/</code>
        </p>
        <p>
          Firmware is built at session startup. Restart <code>mix dev.qemu</code>
          for device-code changes; restarting replaces the disposable disk.
        </p>
      </footer>
    </main>
    """
  end

  defp network_label(:internet), do: "Internet router"
  defp network_label(:equipment), do: "Isolated equipment network"

  defp busy?(run), do: run.blocked || run.status == :running || run.manual_action != nil
  defp completed(run), do: Enum.count(run.rows, &(&1.status in [:passed, :failed]))
  defp selected(run), do: Enum.count(run.rows, &(&1.status != :skipped))
  defp result_tone(:passed), do: "good"
  defp result_tone(:failed), do: "warning"
  defp result_tone(_), do: "neutral"
  defp duration(ms) when ms < 1000, do: "#{ms} ms"
  defp duration(ms), do: "#{Float.round(ms / 1000, 1)} s"

  defp owner_label(%{blocked: true}), do: "Control blocked · restart required"
  defp owner_label(%{mode: :manual}), do: "Manual owns the device · switching modes clears faults"
  defp owner_label(%{status: :running}), do: "Scenario runner owns the device"
  defp owner_label(_), do: "Ready · no active controller"

  defp summary(projection) do
    available = projection.backend.available
    internet = projection.connections.internet.health
    remote = projection.remote_access

    [
      observation(
        "device",
        "Device",
        if(available, do: "Available", else: "Unavailable"),
        available
      ),
      port_observation(projection, "eth0", "WAN · eth0"),
      port_observation(projection, "eth1", "Equipment · eth1"),
      observation(
        "internet",
        "Internet",
        if(available, do: String.capitalize(internet), else: "Unknown"),
        available && internet == "online"
      ),
      observation(
        "tailscale",
        "Tailscale",
        if(available, do: NervesGateWeb.RemoteStatus.label(remote), else: "Unknown"),
        available && remote.available && remote.state == "online"
      )
    ]
  end

  defp port_observation(projection, name, label) do
    port = Enum.find(projection.connections.ports, &(&1.name == name))

    value =
      cond do
        not projection.backend.available or is_nil(port) -> "Unknown"
        not port.present -> "Not installed"
        port.link -> "Link up"
        true -> "Link down"
      end

    observation(name, label, value, value == "Link up")
  end

  defp observation(id, name, label, good),
    do: %{id: id, name: name, label: label, tone: if(good, do: "good", else: "neutral")}
end
