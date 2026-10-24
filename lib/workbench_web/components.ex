defmodule WorkbenchWeb.Components do
  @moduledoc "Small shared workbench components and presentation helpers."
  use Phoenix.Component
  import NervesGateWeb.CoreComponents

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

  attr(:review, :map, required: true)

  def firmware_confirmation(assigns) do
    ~H"""
    <.notice tone="warning" id="firmware-confirmation">
      <p>Update {@review.address}:{@review.port} · {@review.target}</p>
      <p>{@review.current_version} → {@review.version} · serial {@review.serial}</p>
      <p>{@review.firmware}</p>
      <code>SHA-256: {@review.sha256}</code>
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
        <.button type="submit" variant="danger">Update firmware and reboot</.button>
      </form>
    </.notice>
    """
  end

  def operation_path(%{kind: kind}) when kind in ["factory_review", "factory_provision"],
    do: "/factory"

  def operation_path(%{review: %{address: address}}),
    do: Workbench.Devices.physical_path(address) <> "?tab=firmware"

  def operation_path(%{kind: kind}) when kind in ["test", "package", "install"], do: "/apps"

  def operation_path(%{kind: kind})
      when kind in ["firmware_review", "firmware_update", "device_info"],
      do: "/devices"

  def operation_path(_), do: "/firmware"

  def operation_label(nil), do: "No operation"
  def operation_label("device_info"), do: "Read device information"
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
