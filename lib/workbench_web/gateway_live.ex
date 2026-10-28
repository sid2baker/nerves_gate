defmodule WorkbenchWeb.GatewayLive do
  @moduledoc """
  One page per gateway. Live status comes from the gateway's own ProjectionServer,
  for simulated and physical gateways alike. Simulator-owned gateways add bench,
  manual-fault and scenario panels; physical gateways add operator checks and
  reviewed firmware updates.
  """
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  import WorkbenchWeb.Components
  import WorkbenchWeb.Live, only: [command: 2]
  alias NervesGate.Projection
  alias NervesGateWeb.{NetworkStatus, Observations}
  alias Scenarios.Runner
  alias Simulator.Faults

  def mount(%{"node" => node}, _, socket) do
    if connected?(socket) do
      Workbench.Gateways.subscribe()
      Runner.subscribe()
    end

    gateway = Enum.find(Workbench.Gateways.list(), &(to_string(&1.node) == node))

    socket =
      socket
      |> assign(node: node, gateway: gateway, confirm_run: nil, images: Workbench.Builds.images())
      |> put_bench(Runner.snapshot())

    if gateway do
      {:ok,
       Observations.subscribe(
         socket,
         &assign(&1, :projection, &2),
         {NervesGate.ProjectionServer, gateway.node}
       )}
    else
      {:ok, assign(socket, :projection, Projection.disconnected().status)}
    end
  end

  def handle_params(_, _, socket),
    do: {:noreply, assign(socket, :tab, socket.assigns.live_action)}

  def handle_info({:gateways, gateways}, socket) do
    gateway = Enum.find(gateways, &(to_string(&1.node) == socket.assigns.node))

    # First sighting: remount so the projection subscription binds to this node.
    if is_nil(socket.assigns.gateway) and gateway,
      do: {:noreply, push_navigate(socket, to: "/devices/#{socket.assigns.node}")},
      else: {:noreply, socket |> assign(:gateway, gateway) |> put_bench(socket.assigns.bench)}
  end

  def handle_info({:scenarios, bench}, socket), do: {:noreply, put_bench(socket, bench)}

  def handle_event("check", %{"scenario" => id}, socket),
    do: command(socket, Workbench.Jobs.check(socket.assigns.gateway.node, id))

  def handle_event("review_firmware", %{"firmware" => path}, socket) do
    if Enum.any?(socket.assigns.images, &(&1.path == path)),
      do: command(socket, Workbench.Jobs.review_firmware(socket.assigns.gateway.node, path)),
      else: command(socket, {:error, "Select an available EC100 image"})
  end

  def handle_event("confirm_firmware", %{"review_id" => token, "address" => address}, socket),
    do: command(socket, Workbench.Jobs.confirm_firmware(token, address))

  def handle_event("refresh_images", _, socket),
    do: {:noreply, assign(socket, :images, Workbench.Builds.images())}

  def handle_event("mode", %{"mode" => mode}, socket),
    do: command(socket, Runner.mode(socket.assigns.sim_id, mode))

  def handle_event("manual", %{"action" => action}, socket),
    do: command(socket, Runner.manual(socket.assigns.sim_id, action))

  def handle_event("prepare_run", %{"scenario" => scenario}, socket),
    do: {:noreply, assign(socket, confirm_run: scenario, error: nil)}

  def handle_event("cancel_run", _, socket), do: {:noreply, assign(socket, :confirm_run, nil)}

  def handle_event("run", %{"scenario" => scenario}, socket) do
    socket = assign(socket, :confirm_run, nil)
    command(socket, Runner.run(socket.assigns.sim_id, scenario))
  end

  defp put_bench(socket, bench) do
    sim_id = get_in(socket.assigns, [:gateway, :sim_id])
    device = sim_id && bench.devices[sim_id]

    assign(socket,
      bench: bench,
      sim_id: sim_id,
      device: device,
      active:
        device && is_integer(device.owner) && Enum.find(bench.runs, &(&1.id == device.owner)),
      results: results(bench, device)
    )
  end

  defp results(bench, %{run: run}) when not is_nil(run) do
    case Enum.find(bench.runs, &(&1.id == run)) do
      %{rows: rows} -> Map.new(rows, &{&1.id, &1})
      nil -> %{}
    end
  end

  defp results(_, _), do: %{}

  def render(assigns) do
    ~H"""
    <main class="ui-main ui-stack bench" id="gateway-page">
      <.back_link navigate="/devices">Devices</.back_link>
      <.notice :if={!@gateway} tone="warning" role="alert">
        Unknown gateway. It appears here once the Workbench has connected to it.
      </.notice>
      <div :if={@gateway} class="ui-stack">
        <.page_header
          eyebrow={
            if @gateway.source == :qemu,
              do: "Simulated gateway · #{@sim_id}",
              else: "Physical gateway"
          }
          title={to_string(@gateway.node)}
          description={@gateway.address}
        >
          <:actions>
            <.device_kind source={@gateway.source} />
            <.connection gateway={@gateway} />
            <.button
              id="gateway-ui-link"
              href={Workbench.Gateways.url(@gateway)}
              target="_blank"
              rel="noreferrer"
              variant="secondary"
              icon="external"
            >Gateway UI</.button>
          </:actions>
        </.page_header>
        <nav :if={@gateway.source == :qemu} class="dev-filters" aria-label="Device sections">
          <.link
            :for={
              {tab, label, path} <- [
                {:devices, "Status", ""},
                {:scenarios, "Scenarios", "/scenarios"},
                {:manual, "Manual debugging", "/manual"}
              ]
            }
            navigate={"/devices/#{@node}#{path}"}
            aria-current={if @tab == tab, do: "page"}
          >{label}</.link>
        </nav>

        <.panel :if={@tab == :devices} title="Observed device" icon="network" id="device-summary">
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
        </.panel>

        <.panel :if={@tab == :devices && @gateway.identity} title="Identity" icon="info" id="identity">
          <.setting_row label="Target">{@gateway.identity.target}</.setting_row>
          <.setting_row label="Firmware">{@gateway.identity.firmware}</.setting_row>
          <.setting_row label="Source revision">{@gateway.identity.source_revision}</.setting_row>
          <.setting_row label="Serial">{@gateway.identity.serial}</.setting_row>
          <.setting_row label="Runtime">
            Elixir {@gateway.identity.elixir} · OTP {@gateway.identity.otp}
          </.setting_row>
        </.panel>

        <.panel
          :if={@gateway.source == :network}
          title="Operator checks"
          icon="check"
          id="physical-checks"
        >
          <p class="ui-help">
            Run one at a time against this gateway. Read-only unless the check asks you to unplug a cable or press a button; the Workbench sends no commands that change configuration.
          </p>
          <div :for={check <- Scenarios.physical()} class="ui-setting-row" id={"check-#{check.id}"}>
            <span>{check.name}</span>
            <.button
              phx-click="check"
              phx-value-scenario={check.id}
              variant="secondary"
              disabled={!@gateway.connected || @job.status == :running}
            >Run</.button>
          </div>
          <.job :if={@job.kind == "check" && @job.subject == @gateway.node} job={@job} />
        </.panel>

        <.panel
          :if={@gateway.source == :network}
          title="Update firmware"
          icon="settings"
          id="firmware-update"
        >
          <p class="ui-help">
            Review reads identity, health and plugin artifacts over distribution and checks the exact image. Confirming uploads once over verified SSH (known host key, your key) and waits for a healthy new boot. Uncertain outcomes are never retried.
          </p>
          <form id="review-firmware" phx-submit="review_firmware" class="ui-actions">
            <select
              name="firmware"
              required
              disabled={@images == []}
              aria-label="EC100 firmware image"
            >
              <option :for={image <- @images} value={image.path}>
                {image.version} · {image.build}
              </option>
            </select>
            <.button
              type="submit"
              disabled={!@gateway.connected || @images == [] || @job.status == :running}
            >Review</.button>
            <.button type="button" phx-click="refresh_images" variant="secondary">Refresh images</.button>
          </form>
          <.notice
            :if={@job.review && @job.review.kind == :firmware && @job.review.node == @gateway.node}
            tone="warning"
            id="firmware-confirmation"
          >
            <p>{@job.review.current_version} → {@job.review.version} · serial {@job.review.serial}</p>
            <code>Build commit: {@job.review.source_revision}</code>
            <code>SHA-256: {@job.review.sha256}</code>
            <p>
              Expires after ten minutes. Type the exact address to authorize the update and reboot.
            </p>
            <form id="confirm-firmware" phx-submit="confirm_firmware" class="ui-actions">
              <input type="hidden" name="review_id" value={@job.review.token} />
              <input
                type="text"
                name="address"
                placeholder={@job.review.address}
                aria-label="Confirm address"
                autocomplete="off"
                required
              />
              <.button type="submit" variant="danger">Update, reboot and verify</.button>
            </form>
          </.notice>
          <.job
            :if={@job.kind in ["firmware_review", "firmware_update"] && @job.subject == @gateway.node}
            job={@job}
          />
        </.panel>

        <div :if={@gateway.source == :qemu} class="ui-stack">
          <.notice :if={!@device} id="device-not-running" title="Not running">
            <p>{@bench.lifecycle.phase}</p>
            <.link navigate="/develop/firmware#simulator-lifecycle" class="ui-text-link">Start simulated devices</.link>
          </.notice>

          <.panel
            :if={@device && @tab == :devices}
            title="Bench"
            icon="network"
            id="bench-connections"
          >
            <.setting_row :for={port <- [:lan1, :lan2]} label={port_label(port)}>
              <span id={"bench-#{port}-network"}>{network_label(@device.topology[port])}</span>
            </.setting_row>
            <.setting_row label="Faults">
              <span :if={@device.faults == %{}} id="no-faults">None active</span>
              <span :for={{key, label} <- Enum.sort(@device.faults)} id={"fault-#{key}"}><.status tone="warning">
                {label}
              </.status></span>
            </.setting_row>
            <p :if={@device.blocked} role="alert">Control uncertain. Reset the simulated devices.</p>
            <p class="ui-help" id="control-owner">{owner_label(@device)}</p>
          </.panel>

          <.panel
            :if={@device && @tab == :manual}
            title="Manual controls"
            icon="settings"
            id="manual-controls"
          >
            <div class="ui-actions">
              <.button
                :if={!manual?(@device)}
                id="mode-manual"
                phx-click="mode"
                phx-value-mode="manual"
                disabled={busy?(@device)}
              >Acquire manual control</.button>
              <.button
                :if={manual?(@device)}
                id="mode-scenarios"
                variant="secondary"
                phx-click="mode"
                phx-value-mode="scenarios"
                disabled={busy?(@device)}
              >Release manual control</.button>
            </div>
            <div :if={manual?(@device)} class="ui-settings-list">
              <.setting_row :for={control <- Faults.controls()} label={control.name}>
                <div class="ui-actions" role="group" aria-label={control.name}>
                  <.button
                    :for={{action, label} <- control.choices}
                    id={"manual-#{action}"}
                    variant="secondary"
                    phx-click="manual"
                    phx-value-action={action}
                    loading={@device.manual_action == action}
                    disabled={busy?(@device)}
                  >{label}</.button>
                </div>
              </.setting_row>
              <.button
                id="clear-faults"
                phx-click="manual"
                phx-value-action="clear"
                disabled={busy?(@device)}
              >Clear all faults</.button>
            </div>
            <p class="ui-help">
              Manual control reserves the device and blocks scenarios. Attach a shell with <code>iex --name dbg@127.0.0.1 --cookie mycookie --remsh {@gateway.node}</code>.
              Logs are under <code>_build/simulator/</code>.
            </p>
          </.panel>

          <.panel :if={@device && @tab == :scenarios} title="Scenarios" icon="check" id="scenarios">
            <:meta>
              <.button
                id="run-all"
                phx-click="prepare_run"
                phx-value-scenario="all"
                disabled={busy?(@device) || manual?(@device)}
              >Run all</.button>
            </:meta>
            <p class="ui-help">
              Scenarios change device settings. Failed scenarios replace their devices' disks.
            </p>
            <.notice :if={@confirm_run} tone="warning" id="confirm-run" role="alert">
              <p>Start <strong>{@confirm_run}</strong> on {@sim_id}?</p>
              <div class="ui-actions">
                <.button id="confirm-start" phx-click="run" phx-value-scenario={@confirm_run}>Start run</.button>
                <.button variant="quiet" phx-click="cancel_run">Cancel</.button>
              </div>
            </.notice>
            <p :if={@active} role="status" id="run-status">Run #{@active.id} · {@active.phase}</p>
            <ul class="bench-scenarios" id="test-results">
              <li :for={scenario <- @bench.scenarios} id={"scenario-#{scenario.id}"}>
                <div class="bench-scenario-heading">
                  <div>
                    <h3>{scenario.name}</h3>
                    <code class="ui-help">{scenario.id}</code>
                  </div>
                  <.button
                    variant="secondary"
                    phx-click="prepare_run"
                    phx-value-scenario={scenario.id}
                    disabled={busy?(@device) || manual?(@device)}
                  >Run</.button>
                </div>
                <div :if={@results[scenario.id]} class="ui-actions">
                  <.status tone={result_tone(@results[scenario.id].status)}>
                    {@results[scenario.id].status}
                  </.status>
                  <span :if={@results[scenario.id].detail != ""} class="ui-help">{@results[
                    scenario.id
                  ].detail}</span>
                </div>
              </li>
            </ul>
          </.panel>
        </div>
      </div>
    </main>
    """
  end

  defp manual?(device), do: device.owner == :manual

  defp busy?(device),
    do: device.blocked or device.manual_action != nil or device.owner not in [nil, :manual]

  defp network_label(:internet), do: "Internet router"
  defp network_label(:plugin), do: "Isolated plugin network"
  defp network_label(_), do: "Unknown"

  defp owner_label(%{blocked: true}), do: "Control blocked · Reset required"
  defp owner_label(%{owner: :manual}), do: "Manual control owns the device"
  defp owner_label(%{owner: nil}), do: "Ready"
  defp owner_label(%{owner: run}), do: "Run ##{run} owns the device"

  defp summary(projection) do
    available = projection.device.available
    internet = projection.connections.internet.health

    [
      observation(
        "device",
        "Device",
        if(available, do: "Available", else: "Unavailable"),
        available
      ),
      port_observation(projection, "eth0"),
      port_observation(projection, "eth1"),
      observation(
        "internet",
        "Internet",
        if(available, do: String.capitalize(internet), else: "Unknown"),
        available && internet == "online"
      ),
      observation(
        "tailscale",
        "Tailscale",
        if(available, do: NervesGateWeb.RemoteStatus.label(projection.remote), else: "Unknown"),
        available && projection.remote.available && projection.remote.state == "online"
      )
    ]
  end

  defp port_observation(projection, name) do
    port = Enum.find(projection.connections.ports, &(&1.name == name))
    label = Enum.join([name | role(port)], " · ")

    value =
      cond do
        not projection.device.available or is_nil(port) -> "Unknown"
        not port.present -> "Not installed"
        port.link -> "Link up"
        true -> "Link down"
      end

    observation(name, label, value, value == "Link up")
  end

  defp role(%{role: role}) when role != "unassigned", do: [NetworkStatus.role_label(role)]
  defp role(_), do: []

  defp observation(id, name, label, good),
    do: %{id: id, name: name, label: label, tone: if(good, do: "good", else: "neutral")}
end
