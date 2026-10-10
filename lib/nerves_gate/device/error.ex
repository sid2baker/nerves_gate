defmodule NervesGate.Device.Error do
  @moduledoc false

  def new(code, message), do: %{code: code, message: message}

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

  def from(:stale_revision),
    do:
      new("stale_revision", "Device state changed. Review the current state before trying again.")

  def from({:apply, _}),
    do: new("apply_failed", "Could not apply settings. Restoring saved settings.")

  def from({:save, _}),
    do: new("save_failed", "Could not save settings. Restoring saved settings.")

  def from({:restore, _}), do: from(:recovery_in_progress)
  def from({:load, _}), do: from(:invalid_saved_config)
  def from({:discovery, _}), do: new("discovery_failed", "Connection status is unavailable.")
  def from(reason) when is_binary(reason), do: new("invalid_parameters", reason)
  def from(_), do: new("execution_failed", "The operation failed. Check device diagnostics.")
end
