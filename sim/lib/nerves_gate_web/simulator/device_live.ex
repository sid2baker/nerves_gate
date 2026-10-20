defmodule NervesGateWeb.Simulator.DeviceLive do
  @moduledoc "One simulated device: its live projection, faults, manual controls and scenarios."
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  alias NervesGate.{ManualFaults, Projection, QemuTests}
  alias NervesGateWeb.Observations
  alias NervesGateWeb.Simulator.OverviewLive

  def mount(%{"id" => id}, _, socket) do
    if connected?(socket), do: QemuTests.subscribe()
    bench = QemuTests.snapshot()
    socket = assign(socket, bench: bench, id: id, error: nil, confirm_run: nil)

    # The device's own ProjectionServer, exactly as its gateway UI observes it.
    case config(bench, id) do
      nil ->
        {:ok, assign(socket, :projection, Projection.disconnected().status)}

      config ->
        {:ok, Observations.subscribe(socket, &assign(&1, :projection, &2), config.node)}
    end
  end

  def handle_event("mode", %{"mode" => mode}, socket),
    do: command(socket, QemuTests.mode(socket.assigns.id, mode))

  def handle_event("manual", %{"action" => action}, socket),
    do: command(socket, QemuTests.manual(socket.assigns.id, action))

  def handle_event("prepare_run", %{"scenario" => scenario}, socket),
    do: {:noreply, assign(socket, confirm_run: scenario, error: nil)}

  def handle_event("cancel_run", _, socket),
    do: {:noreply, assign(socket, :confirm_run, nil)}

  def handle_event("run", %{"scenario" => scenario}, socket),
    do: command(socket, QemuTests.run(socket.assigns.id, scenario))

  def handle_info({:qemu_tests, bench}, socket) do
    previous = config(socket.assigns.bench, socket.assigns.id)
    current = config(bench, socket.assigns.id)
    socket = assign(socket, :bench, bench)

    # Adding/removing devices can change the sorted serial/address assignment.
    # Remount rather than leaving this page subscribed to a different device.
    if previous != current,
      do: {:noreply, push_navigate(socket, to: "/devices/#{socket.assigns.id}")},
      else: {:noreply, socket}
  end

  defp command(socket, {:error, message}), do: {:noreply, assign(socket, error: message)}
  defp command(socket, {:ok, _}), do: command(socket, :ok)

  defp command(socket, :ok),
    do: {:noreply, assign(socket, bench: QemuTests.snapshot(), error: nil, confirm_run: nil)}

  def render(assigns) do
    device = device(assigns.bench, assigns.id)

    assigns =
      assign(assigns,
        config: config(assigns.bench, assigns.id),
        device: device,
        active: active_run(assigns.bench, device),
        results: results(assigns.bench, device)
      )

    ~H"""
    <main class="ui-main ui-stack bench" id="device-tests">
      <.link navigate="/" class="ui-text-link">← Simulator</.link>
      <.page_header
        eyebrow="Development · owned QEMU only"
        title={@id}
        description={if @config, do: "#{@config.node} · #{@config.address}", else: "Unknown device"}
      />
      <div class="ui-disconnected">
        <.notice tone="warning" role="alert">
          Connection to the simulator lost. Controls and observations may be stale; connections and faults remain active.
        </.notice>
      </div>
      <.panel
        :if={@config}
        title="Gateway UI"
        description="The device serves the release UI; mix dev.ui serves it with code reload"
        icon="network"
        id="device-ui"
      >
        <p :if={@device}>
          <a
            href={@device.ui}
            target="_blank"
            rel="noreferrer"
            class="ui-text-link"
            id="device-ui-link"
          >
            {@device.ui}
          </a>
        </p>
        <p :if={!@device} class="ui-help">Start the devices to open the gateway UI.</p>
        <p class="ui-help">Workstation UI: <code>mix dev.ui {@id}</code></p>
      </.panel>

      <.panel
        :if={@config}
        title="Observed device"
        description="Live summary from this device's projection"
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
        <p :if={@device && @device.faults["vm"]} class="ui-help">
          VM pause is injected. The projection may show its last observation until the connection times out.
        </p>
      </.panel>

      <.panel
        :if={@device}
        title="Bench connections"
        description={if @device.blocked, do: "Last confirmed; current connections unknown"}
        icon="network"
        id="bench-connections"
      >
        <.setting_row :for={port <- [:lan1, :lan2]} label={String.upcase(to_string(port))}>
          <span id={"bench-#{port}-network"}>{network_label(@device.topology[port])}</span>
        </.setting_row>
        <.setting_row label="Management">Local control only · no Internet forwarding</.setting_row>
      </.panel>

      <section :if={@device} class="bench-faults" id="active-faults" aria-label="Injected faults">
        <div>
          <h2>Injected faults</h2>
          <p class="ui-help">These are deliberate disruptions, not observed device failures.</p>
        </div>
        <p :if={@device.blocked} role="alert">
          Unknown — last confirmed faults below. Reset the devices before starting again.
        </p>
        <p :if={@device.faults == %{} && !@device.blocked} id="no-faults">None active</p>
        <ul :if={@device.faults != %{}} class="bench-fault-list">
          <li :for={{key, label} <- Enum.sort(@device.faults)} id={"fault-#{key}"}>
            <.status tone="warning">{label}</.status>
          </li>
        </ul>
      </section>

      <.notice :if={@error} tone="warning" role="alert" id="bench-error">{@error}</.notice>
      <div :if={@config} class="bench-toolbar">
        <div class="ui-actions" role="group" aria-label="Device control mode">
          <.button
            id="mode-scenarios"
            variant="secondary"
            phx-click="mode"
            phx-value-mode="scenarios"
            aria-pressed={to_string(!manual?(@device))}
            disabled={busy?(@device)}
          >Scenarios</.button>
          <.button
            id="mode-manual"
            variant="secondary"
            phx-click="mode"
            phx-value-mode="manual"
            aria-pressed={to_string(manual?(@device))}
            disabled={busy?(@device) || manual?(@device)}
          >Manual</.button>
        </div>
        <p class="ui-help" id="control-owner">{owner_label(@bench, @device)}</p>
      </div>

      <div :if={@config} class="ui-stack">
        <.panel
          :if={manual?(@device)}
          title="Manual controls"
          description="Reversible faults only; management networking is never faulted"
          icon="settings"
          id="manual-controls"
        >
          <.notice>
            Manual control is shared by every browser and blocks scenario runs on this device.
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
                  disabled={busy?(@device)}
                >{label}</.button>
              </div>
            </.setting_row>
          </div>
          <.button
            id="clear-faults"
            phx-click="manual"
            phx-value-action="clear"
            disabled={busy?(@device)}
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
          :if={!manual?(@device)}
          title="Scenarios"
          description="The same Elixir scenarios in the site, CLI and CI"
          icon="check"
          id="scenarios"
        >
          <:meta>
            <.button
              id="run-all"
              phx-click="prepare_run"
              phx-value-scenario="all"
              disabled={busy?(@device)}
            >Run all</.button>
          </:meta>
          <p class="ui-help">
            Scenarios change device settings. Fresh-disk scenarios erase enrollment; failed scenarios
            replace their devices' disks. Scenarios marked "all devices" hold every device, so Run all does too.
          </p>
          <.notice :if={@confirm_run} tone="warning" id="confirm-run" role="alert">
            <p>
              Start <strong>{@confirm_run}</strong>
              on {@id}? Device settings may change and disk replacement erases Tailscale enrollment.
            </p>
            <div class="ui-actions">
              <.button
                id="confirm-start"
                phx-mounted={Phoenix.LiveView.JS.focus()}
                phx-click="run"
                phx-value-scenario={@confirm_run}
                disabled={busy?(@device)}
              >Start run</.button>
              <.button variant="quiet" phx-click="cancel_run">Cancel</.button>
            </div>
          </.notice>
          <p :if={@active} role="status" aria-live="polite" id="run-status">
            Run #{@active.id} · {@active.phase}
          </p>
          <ul
            class="bench-scenarios"
            id="test-results"
            tabindex="0"
            aria-label="Available scenarios"
          >
            <li :for={scenario <- @bench.scenarios} id={"scenario-#{scenario.id}"}>
              <div class="bench-scenario-heading">
                <div>
                  <h3>{scenario.name}</h3>
                  <p class="ui-help">
                    <code>{scenario.id}</code><span
                      :if={scenario.fresh_disk}
                      class="bench-destructive"
                    > · fresh disk</span><span :if={scenario.all}> · all devices</span>
                  </p>
                </div>
                <.button
                  variant="secondary"
                  phx-click="prepare_run"
                  phx-value-scenario={scenario.id}
                  disabled={busy?(@device)}
                  aria-label={"Run #{scenario.id}"}
                >Run</.button>
              </div>
              <div :if={@results[scenario.id]} class="ui-actions">
                <.status tone={OverviewLive.result_tone(@results[scenario.id].status)}>
                  {@results[scenario.id].status}
                </.status>
                <span :if={@results[scenario.id].milliseconds} class="ui-help">
                  {duration(@results[scenario.id].milliseconds)}
                </span>
              </div>
              <details :if={failure(@results[scenario.id])}>
                <summary>Failure details</summary>
                <pre class="ui-bus-data">{failure(@results[scenario.id])}</pre>
              </details>
            </li>
          </ul>
        </.panel>
      </div>
    </main>
    """
  end

  defp config(bench, id), do: Enum.find(bench.lifecycle.devices, &(Atom.to_string(&1.id) == id))

  defp device(bench, id),
    do:
      Enum.find_value(bench.devices, fn {key, device} ->
        if Atom.to_string(key) == id, do: device
      end)

  defp manual?(device), do: device != nil and device.owner == :manual

  defp busy?(nil), do: true

  defp busy?(device),
    do: device.blocked or device.manual_action != nil or device.owner not in [nil, :manual]

  defp active_run(bench, %{owner: id}) when is_integer(id),
    do: Enum.find(bench.runs, &(&1.id == id))

  defp active_run(_, _), do: nil

  # Results of the latest run started from this device.
  defp results(_, nil), do: %{}

  defp results(bench, device) do
    case Enum.find(bench.runs, &(&1.id == device.run)) do
      %{rows: rows} -> Map.new(rows, &{&1.id, &1})
      nil -> %{}
    end
  end

  defp failure(%{status: :failed, detail: detail}) when detail != "", do: detail
  defp failure(_), do: nil

  defp network_label(:internet), do: "Internet router"
  defp network_label(:equipment), do: "Isolated equipment network"

  defp duration(ms) when ms < 1000, do: "#{ms} ms"
  defp duration(ms), do: "#{Float.round(ms / 1000, 1)} s"

  defp owner_label(%{lifecycle: %{status: :unavailable}}, _),
    do: "Simulator unavailable · restart mix dev"

  defp owner_label(%{lifecycle: %{status: status}}, nil), do: "Devices #{status}"
  defp owner_label(_, %{blocked: true}), do: "Control blocked · Reset required"

  defp owner_label(_, %{owner: :manual}),
    do: "Manual owns the device · switching modes clears faults"

  defp owner_label(_, %{owner: nil}), do: "Ready · no active controller"
  defp owner_label(_, %{owner: run}), do: "Run ##{run} owns the device"

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
