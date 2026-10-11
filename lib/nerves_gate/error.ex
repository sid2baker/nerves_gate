defmodule NervesGate.Error do
  @moduledoc false

  def new(code, message), do: %{code: code, message: message}

  def from(%{code: code, message: message}) when is_binary(code) and is_binary(message),
    do: new(code, message)

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
        "Network addresses overlap. Previous settings have been restored. Choose different Internet, equipment and USB subnets."
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
        "Route state is not yet known. A timed-out change may still complete. Withdraw the affected route and wait for verified readback before changing LAN roles."
      )

  def from(:sharing_active),
    do: new("sharing_active", "Withdraw advertised 4via6 routes before changing LAN settings.")

  def from(:sharing_confirmation),
    do:
      new(
        "sharing_confirmation",
        "Confirm that the site ID is unique in your tailnet and that you are authorized to share this equipment."
      )

  def from(:sharing_site_id),
    do:
      new(
        "sharing_site_id",
        "Use a site ID from 0 to 65535 assigned uniquely within your tailnet."
      )

  def from(:sharing_version),
    do: new("sharing_version", "Safe 4via6 sharing requires Tailscale 1.102.3 or newer.")

  def from(:sharing_route),
    do:
      new(
        "sharing_route",
        "Select an exact advertised or uncertain equipment route. Other routes are not changed."
      )

  def from(:sharing_stale),
    do:
      new(
        "sharing_stale",
        "An advertised 4via6 route does not match the active dedicated equipment subnet. Withdraw stale routes before adding another."
      )

  def from(:led_unavailable),
    do: new("led_unavailable", "The run LED is unavailable or controlled by a kernel trigger.")

  def from(:led_restore_failed),
    do:
      new(
        "led_restore_failed",
        "Could not restore the previous LED value. Identify is blocked; restoration will be retried."
      )

  def from(:button_mode),
    do:
      new(
        "invalid_parameters",
        "Choose disabled or identify for the button. No reset action is supported."
      )

  def from(:button_unavailable),
    do: new("button_unavailable", "The EC100 user button is unavailable.")

  def from(reason) when is_binary(reason) do
    new("invalid_parameters", reason)
  end

  def from(_), do: new("execution_failed", "The operation failed. Check device diagnostics.")
end
