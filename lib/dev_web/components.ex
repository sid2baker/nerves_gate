defmodule DevWeb.Components do
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
    ~H"""
    <div id={@id} class="ui-stack">
      <p role="status">{operation_label(@operation.kind)} · {@operation.status}</p>
      <div :if={@operation.status == :running} class="ui-progress"></div>
      <code :if={@operation.output} class="bench-output">{@operation.output}</code>
      <p :if={@operation.result} class="dev-result">{@operation.result}</p>
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

  def operation_path(%{review: %{address: address}}),
    do: Dev.Devices.physical_path(address) <> "?tab=firmware"

  def operation_path(%{kind: kind}) when kind in ["test", "package", "install"], do: "/apps"

  def operation_path(%{kind: kind})
      when kind in ["firmware_review", "firmware_update", "device_info"],
      do: "/devices"

  def operation_path(_), do: "/firmware"

  def operation_label(nil), do: "No operation"
  def operation_label("device_info"), do: "Read device information"
  def operation_label("firmware_review"), do: "Firmware review"
  def operation_label("firmware_update"), do: "Firmware update"
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
