defmodule WorkbenchWeb.Components do
  @moduledoc "Small shared workbench components and presentation helpers."
  use Phoenix.Component
  import NervesGateWeb.CoreComponents

  attr(:section, :atom, required: true)

  def develop_navigation(assigns) do
    ~H"""
    <nav class="dev-filters" aria-label="Development workspace">
      <.link navigate="/develop/applications" aria-current={if @section == :apps, do: "page"}>Develop an application</.link>
      <.link navigate="/develop/firmware" aria-current={if @section == :firmware, do: "page"}>Build and test firmware</.link>
    </nav>
    """
  end

  attr(:kind, :atom, required: true, values: [:physical, :simulated])

  def device_kind(assigns) do
    ~H"""
    <span class={["ui-badge", @kind == :simulated && "dev-badge--simulated"]} data-device-kind={@kind}>
      {if @kind == :simulated, do: "Simulated · QEMU", else: "Physical"}
    </span>
    """
  end

  attr(:operation, :map, required: true)
  attr(:id, :string, default: "workbench-operation")

  def operation(assigns) do
    assigns =
      assign(assigns,
        connection: Map.get(assigns.operation, :connection),
        recovery: Map.get(assigns.operation, :recovery)
      )

    ~H"""
    <div id={@id} class="ui-stack">
      <p role="status">{operation_label(@operation.kind)} · {@operation.status}</p>
      <p :if={@operation[:context]} class="ui-help">
        {@operation.context[:subject] || @operation.context[:address]}
        <span :if={@operation.context[:device]}> · Simulated device: {@operation.context.device}</span>
      </p>
      <div :if={@operation.status == :running} class="ui-progress"></div>
      <.notice :if={@operation.result && @operation.status == :failed} tone="warning" role="alert">
        {@operation.result}
      </.notice>
      <p :if={@recovery} class="dev-result">
        Preserve recovery files: <code>{@recovery.backup}</code>
      </p>
      <.notice :if={@recovery && Map.get(@recovery, :backup_enabled, true) == false} tone="warning">
        Full eMMC backup was explicitly skipped. Readbacks are verification artifacts, not a backup of the previous firmware/data.
      </.notice>
      <code :if={@operation.output} class="bench-output">{@operation.output}</code>
      <p :if={@operation[:checks]}>
        {if @operation.kind == "hardware_failover",
          do: "Assisted test profile:",
          else: "Read-only readiness profile:"} {@operation.checks.profile}
      </p>
      <p
        :if={@operation[:checks] && @operation.checks[:observed]}
        class="ui-help"
        id="hardware-observed-network"
      >
        Observed profile: {@operation.checks.observed["mode"] || "unknown"} ·
        selected: {@operation.checks.observed["selected"] || "none"} ·
        Ethernet: {@operation.checks.observed["ethernet"] || "unknown"} ·
        4G: {@operation.checks.observed["cellular"] || "unknown"} ·
        Internet: {@operation.checks.observed["health"] || "unknown"}
      </p>
      <pre :if={@operation[:diagnostic_report]} class="ui-bus-data" id="hardware-diagnostic-report">{Jason.encode!(@operation.diagnostic_report, pretty: true)}</pre>
      <ul :if={@operation[:checks]} class="bench-scenarios" id="hardware-check-results">
        <li :for={row <- @operation.checks.rows}>
          <strong>{row.id}</strong>
          ·
          <.status tone={result_tone(row.status)}>{row.status}</.status>
          <pre :if={row.detail != ""} class="ui-bus-data">{row.detail}</pre>
        </li>
      </ul>
      <p :if={@operation.result && @operation.status != :failed} class="dev-result">
        {@operation.result}
      </p>
      <p :if={@connection && @connection.status == :waiting}>
        Flash verified · waiting for USB reboot and device information…
      </p>
      <.notice
        :if={@connection && @connection.status == :unavailable}
        tone="warning"
        id="factory-reconnect-warning"
      >
        {@connection.message}
      </.notice>
      <div
        :if={@connection && @connection.status == :connected}
        id="factory-connected"
        class="ui-stack"
      >
        <strong>Connected over USB · device information read</strong>
        <.setting_row label="Address">
          {@connection.device.address} · {@connection.device.interface}
        </.setting_row>
        <.setting_row label="Running firmware">{@connection.device.version}</.setting_row>
        <.setting_row label="Target">{@connection.device.target}</.setting_row>
        <.setting_row label="Runtime">{@connection.device.runtime}</.setting_row>
        <p class="ui-help">
          Read at {@connection.device.read_at}. Direct USB HTTP observation, not authenticated SSH identity or a persistent live connection.
        </p>
        <div class="ui-actions">
          <.button href={@connection.device.url} target="_blank" rel="noreferrer">Open gateway</.button>
          <.link
            navigate={Workbench.Devices.physical_path(@connection.device.address)}
            class="ui-text-link"
          >View device information</.link>
        </div>
      </div>
    </div>
    """
  end

  attr(:operation, :map, required: true)
  attr(:address, :string, required: true)
  attr(:kinds, :list, required: true)

  def procedure_result(assigns) do
    assigns =
      assign(
        assigns,
        :matches,
        assigns.operation.kind in assigns.kinds and
          hd(String.split(operation_path(assigns.operation), "?")) ==
            Workbench.Devices.physical_path(assigns.address)
      )

    ~H"""
    <div :if={@matches} class="ui-stack">
      <.notice
        :if={
          @operation.status == :running && @operation.kind in ["hardware_failover", "reboot_verify"]
        }
        id="hardware-observation-running"
      >
        <p>
          Follow the progress instructions here. Restore Ethernet cables if the test fails or the workbench disconnects. Stopping observation waits for the current bounded read; it cannot undo a physical action.
        </p>
        <.button phx-click="cancel_observation" variant="secondary">Stop observation</.button>
      </.notice>
      <.operation operation={@operation} />
    </div>
    """
  end

  attr(:review, :map, required: true)

  def firmware_confirmation(assigns) do
    ~H"""
    <.notice tone="warning" id="firmware-confirmation">
      <p>Update {@review.address}:{@review.port} · {@review.target}</p>
      <p>{@review.current_version} → {@review.version} · serial {@review.serial}</p>
      <p>{@review.firmware}</p>
      <code>SHA-256: {@review.sha256}</code>
      <p :if={@review[:verify_ssh]}>
        SSH update-and-verify procedure. Reconnect verification requires the same identity, a new boot, reviewed firmware and healthy state. If LAN/Tailscale access does not return, inspect the device; no update is retried.
      </p>
      <p :if={@review[:verify_usb]}>
        USB update-and-verify procedure · {@review.management}. A new boot, reviewed version, unchanged identity and healthy state must be observed. An incomplete verification never retries the upload.
      </p>
      <p>
        Review expires after ten minutes. Keep power connected. Type the exact reviewed
        hostname/address to authorize this update and reboot.
      </p>
      <form id="confirm-firmware" phx-submit="confirm_firmware" class="ui-stack">
        <input type="hidden" name="review_id" value={@review.token} />
        <input
          type="text"
          name="address"
          aria-label="Confirm update hostname or address"
          autocomplete="off"
          required
        />
        <.button type="submit" variant="danger">
          {cond do
            @review[:verify_usb] -> "Update, reboot and verify over USB"
            @review[:verify_ssh] -> "Update, reboot and verify over SSH"
            true -> "Update firmware and reboot"
          end}
        </.button>
      </form>
    </.notice>
    """
  end

  def operation_path(%{kind: kind}) when kind in ["factory_review", "factory_provision"] do
    "/provision"
  end

  def operation_path(%{kind: kind, context: %{subject: path}})
      when kind in ["app_install_review", "app_install"] and is_binary(path),
      do: "/develop/applications/" <> Base.url_encode64(path, padding: false)

  def operation_path(%{review: %{address: address}}),
    do: Workbench.Devices.physical_path(address) <> "?tab=firmware"

  def operation_path(%{kind: kind, context: %{subject: path}})
      when kind in ["test", "package", "install"] and is_binary(path),
      do: "/develop/applications/" <> Base.url_encode64(path, padding: false)

  def operation_path(%{context: %{address: address}}) when is_binary(address),
    do: Workbench.Devices.physical_path(address) <> "?tab=firmware"

  def operation_path(%{kind: kind, context: %{subject: address}})
      when kind in ["hardware_diagnostics", "reboot_review", "reboot_verify"],
      do: Workbench.Devices.physical_path(address) <> "?tab=firmware"

  def operation_path(%{kind: kind, context: %{subject: address}})
      when kind in ["hardware_test", "hardware_failover"],
      do: Workbench.Devices.physical_path(address) <> "?tab=tests"

  def operation_path(%{kind: "find_usb"}), do: "/devices"

  def operation_path(%{kind: "device_info", context: %{subject: address}}),
    do: Workbench.Devices.physical_path(address)

  def operation_path(%{kind: kind}) when kind in ["test", "package", "install"],
    do: "/develop/applications"

  def operation_path(%{kind: kind})
      when kind in ["firmware_review", "firmware_update", "device_info"],
      do: "/devices"

  def operation_path(_), do: "/develop/firmware"

  def operation_label(nil), do: "No operation"
  def operation_label("device_info"), do: "Read device information"
  def operation_label("find_usb"), do: "Find USB gateways"
  def operation_label("hardware_test"), do: "Hardware readiness"
  def operation_label("hardware_failover"), do: "Assisted Ethernet / 4G failover"
  def operation_label("hardware_diagnostics"), do: "Diagnostic snapshot"
  def operation_label("reboot_review"), do: "Reboot observation review"
  def operation_label("reboot_verify"), do: "Observe physical-button reboot"
  def operation_label("app_install_review"), do: "Review physical app installation"
  def operation_label("app_install"), do: "Install stopped application over SSH"
  def operation_label("firmware_review"), do: "Firmware review"
  def operation_label("firmware_update"), do: "Firmware update"
  def operation_label("factory_review"), do: "Factory review"
  def operation_label("factory_provision"), do: "Factory provisioning"
  def operation_label(kind), do: String.capitalize(kind)

  def port_label(:lan1), do: "LAN1"
  def port_label(:lan2), do: "LAN2"
  def result_tone(:passed), do: "good"
  def result_tone(:succeeded), do: "good"
  def result_tone(:awaiting_confirmation), do: "warning"
  def result_tone(:failed), do: "warning"
  def result_tone(:running), do: "busy"
  def result_tone(_), do: "neutral"
end
