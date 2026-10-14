defmodule NervesGate.Error do
  @moduledoc false

  def new(code, message), do: %{code: code, message: message}

  def from(%{code: code, message: message}) when is_binary(code) and is_binary(message),
    do: new(code, message)

  def from(:cellular_unsupported),
    do:
      new(
        "cellular_unsupported",
        "Cellular setup needs a qualified modem driver and dedicated interface in this firmware."
      )

  def from(:invalid_saved_config),
    do:
      new("invalid_saved_config", "Saved settings could not be read. Use recovery SSH or serial.")

  def from(:trial_in_progress),
    do: new("trial_in_progress", "Another client already started a trial.")

  def from(:recovery_in_progress),
    do: new("recovery_in_progress", "Wait for saved settings to be restored before trying again.")

  def from(:no_matching_trial),
    do: new("no_matching_trial", "This trial has ended. Review your settings again.")

  def from(:not_connected),
    do:
      new(
        "not_connected",
        "Port settings are not ready to save. Check the connection status and any address conflicts below."
      )

  def from(:conflicting_networks),
    do:
      new(
        "conflicting_networks",
        "Network addresses overlap. Previous settings have been restored. Choose different Ethernet, cellular, equipment and USB subnets."
      )

  def from(:expired),
    do: new("expired", "The trial expired. Previous settings are being restored.")

  def from(:unavailable),
    do:
      new("unavailable", "Network control is unavailable. Reconnect and read the current state.")

  def from(:outcome_unknown),
    do:
      new(
        "outcome_unknown",
        "The command reply was lost. Read the current state before retrying."
      )

  def from({:apply, _}),
    do: new("apply_failed", "Could not apply settings. Restoring saved settings.")

  def from({:save, _}),
    do: new("save_failed", "Could not save settings. Restoring saved settings.")

  def from({:restore, _}), do: from(:recovery_in_progress)
  def from({:load, _}), do: from(:invalid_saved_config)
  def from({:discovery, _}), do: new("discovery_failed", "Connection status is unavailable.")

  def from(:operation_in_progress) do
    new("operation_in_progress", "Wait for the current operation to finish.")
  end

  def from(:operation_timeout) do
    new("operation_timeout", "The operation exceeded its time limit.")
  end

  def from(:equipment_unconfigured) do
    new("equipment_unconfigured", "Configure and save a static equipment address first.")
  end

  def from(:equipment_not_ready) do
    new(
      "equipment_not_ready",
      "The confirmed equipment address and link must be present before scanning or sharing."
    )
  end

  def from(:network_unavailable) do
    new(
      "network_unavailable",
      "Wait for network settings to be confirmed and recovery to finish."
    )
  end

  def from(:equipment_unavailable) do
    new("equipment_unavailable", "Equipment observations are unavailable.")
  end

  def from(:equipment_changed) do
    new("equipment_changed", "This equipment observation has changed. Refresh and try again.")
  end

  def from(:invalid_label) do
    new("invalid_label", "Use a label of at most 64 characters without control characters.")
  end

  def from(:label_limit) do
    new("label_limit", "The 256-label limit has been reached. Remove an unused label first.")
  end

  def from(:labels_unavailable) do
    new(
      "labels_unavailable",
      "Saved labels could not be read or written. Existing labels have not been replaced."
    )
  end

  def from(:scan_interrupted) do
    new("scan_interrupted", "The scan was interrupted. Network settings were not changed.")
  end

  def from(:sharing_dedicated_only),
    do:
      new(
        "sharing_dedicated_only",
        "Sharing requires a confirmed, dedicated equipment port. Shared LAN and USB cannot be advertised."
      )

  def from(:sharing_unknown),
    do:
      new(
        "sharing_unknown",
        "Sharing state is unknown. Turn sharing off and wait for confirmation before changing LAN settings."
      )

  def from(:sharing_active),
    do:
      new(
        "sharing_active",
        "Turn equipment sharing off before changing LAN settings. Remove any other subnet advertisements in Tailscale as well."
      )

  def from(:bus_unsupported),
    do: new("bus_unsupported", "Bus diagnostics are unsupported on this target or unavailable.")

  def from(:bus_missing), do: new("bus_missing", "The selected bus interface is not detected.")
  def from(:bus_disabled), do: new("bus_disabled", "Enable this interface in Bus settings first.")

  def from(:bus_parameters),
    do: new("invalid_parameters", "Choose a supported bus port, enabled state and CAN bitrate.")

  def from(:can_not_passive),
    do:
      new(
        "can_not_passive",
        "CAN capture requires an enabled interface in listen-only mode. Configure it in Settings."
      )

  def from(:bus_failed),
    do:
      new(
        "bus_failed",
        "Bus operation failed. Check wiring, permissions and interface state. Settings may be partially applied; no retry was sent."
      )

  def from(:bus_timeout),
    do:
      new(
        "bus_timeout",
        "Bus operation exceeded its time limit and was stopped. Recheck interface state; no retry was sent."
      )

  def from(:serial_busy),
    do:
      new(
        "serial_busy",
        "Serial traffic was observed before the request. Nothing was sent; do not compete with another master."
      )

  def from(:modbus_parameters),
    do:
      new(
        "invalid_parameters",
        "Authorize one read on ttyS3/ttyS4: unit 1–247, function 3/4, zero-based address 0–65535 and 1–32 registers within range."
      )

  def from(:modbus_timeout),
    do: new("modbus_timeout", "No complete Modbus response within one second. No retry was sent.")

  def from(:modbus_response),
    do:
      new(
        "modbus_response",
        "Invalid or unrelated Modbus response (address, function, length or CRC). No retry was sent."
      )

  def from(:invalid_ssh_key),
    do:
      new(
        "invalid_ssh_key",
        "Paste one OpenSSH public key (Ed25519, RSA or ECDSA), without key options. Never paste a private key."
      )

  def from(:ssh_key_limit),
    do: new("ssh_key_limit", "The 32-key limit has been reached. Remove an unused key first.")

  def from(:ssh_key_not_found),
    do: new("ssh_key_not_found", "This SSH key is no longer present. Refresh the key list.")

  def from(:ssh_keys_unavailable),
    do:
      new(
        "ssh_keys_unavailable",
        "SSH keys could not be read or saved. Existing keys have not been replaced."
      )

  def from(:led_unavailable),
    do: new("led_unavailable", "A status LED is unavailable or controlled by a kernel trigger.")

  def from(:led_restore_failed),
    do:
      new(
        "led_restore_failed",
        "Could not apply the status LEDs. Identify is blocked; LED control will be retried."
      )

  def from(:firmware_update_pending),
    do:
      new(
        "firmware_update_pending",
        "An SSH firmware upload was admitted. Reboot before recovery."
      )

  def from(:data_partition_unavailable),
    do:
      new(
        "data_partition_unavailable",
        "The EC100 data partition is not mounted read-write as ext4."
      )

  def from(:data_quiesce_failed),
    do:
      new(
        "data_quiesce_failed",
        "Could not stop data writers. Reset was aborted; services stay stopped."
      )

  def from(:data_unmount_failed),
    do:
      new(
        "data_unmount_failed",
        "Could not unmount all data mounts. Reset was aborted; services stay stopped."
      )

  def from(:factory_reset_incomplete),
    do:
      new(
        "factory_reset_incomplete",
        "Factory reset did not complete. Services remain stopped; no retry was sent."
      )

  def from(:recovery_unavailable),
    do: new("recovery_unavailable", "Recovery is unavailable on this target.")

  def from(:recovery_already_requested),
    do:
      new(
        "recovery_already_requested",
        "Recovery was already requested. No second attempt was sent."
      )

  def from(:recovery_outcome_unknown),
    do:
      new(
        "recovery_outcome_unknown",
        "Recovery did not complete in time or its result was lost. No retry was sent."
      )

  def from(:button_unavailable),
    do: new("button_unavailable", "The EC100 user button is unavailable.")

  def from(reason) when is_binary(reason) do
    new("invalid_parameters", reason)
  end

  def from(_), do: new("execution_failed", "The operation failed. Check device diagnostics.")
end
