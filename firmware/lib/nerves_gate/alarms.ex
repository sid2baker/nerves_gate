defmodule NervesGate.Alarms do
  @moduledoc """
  Domain-owned conditions and Alarmist policy; no monitor or automatic remedies.

  Raw IDs are `{NervesGate.Alarms, server_name, fault}`. Availability conditions
  are debug-level inputs to `NervesGate.Alarms.Warning`, which requires two seconds
  of continuous failure. Restore/recovery failures are immediate error-level alarms.
  Subscribe with `Alarmist.subscribe_all/0`, then read `Alarmist.get_alarms/0`.

  Each domain registers its faults at startup. Reporting stays asynchronous so a
  stalled alarm handler cannot delay hardware rollback. Unknown observations retain
  the last report; unnamed instances do not report. No alarm is proof of readiness.
  """

  @critical [:network_restore_failed, :led_restore_failed, :recovery_failed]

  @doc false
  def register(nil, _faults), do: :ok

  def register(name, faults) do
    registered = Alarmist.managed_alarm_ids()

    for fault <- faults do
      level = if fault in @critical, do: :error, else: :debug
      Alarmist.set_alarm_level({__MODULE__, name, fault}, level)
      managed = {__MODULE__.Warning, name, fault}

      # Re-adding a rule resets its timers in Alarmist 0.4. Keep them across
      # producer restarts; only a factual report may change the condition.
      if level == :debug and managed not in registered,
        do: Alarmist.add_managed_alarm(managed)
    end

    :ok
  end

  @doc "Read Alarmist severity and managed connectivity faults for the LED policy."
  def indication(network, remote) do
    active = Alarmist.get_alarm_ids()

    severity =
      cond do
        Alarmist.get_alarm_ids(level: :error) != [] -> :error
        active != [] -> :warning
        true -> :none
      end

    connection =
      Enum.any?(
        [
          {network, :internet_unavailable},
          {remote, :remote_unavailable},
          {remote, :remote_offline},
          {remote, :remote_health}
        ],
        fn {name, fault} -> {__MODULE__.Warning, name, fault} in active end
      )

    %{severity: severity, connection: connection}
  end

  # Unknown observations leave the last report unchanged.
  @doc false
  def report(_fault, _name, nil), do: :ok
  def report(_fault, nil, _active), do: :ok

  def report(fault, name, active) do
    id = {__MODULE__, name, fault}
    event = if active, do: {:set_alarm, {id, message(fault)}}, else: {:clear_alarm, id}

    if handler = Process.whereis(:alarm_handler), do: :gen_event.notify(handler, event)
    :ok
  end

  defp message(:network_restore_failed), do: "Saved network settings could not be restored."

  defp message(:internet_unavailable),
    do: "No configured Internet uplink has Internet connectivity."

  defp message(:internet_backup), do: "Internet access is using the 4G backup."
  defp message(:cellular_unavailable), do: "The configured cellular connection is unavailable."
  defp message(:led_restore_failed), do: "Status LED control is unavailable."
  defp message(:recovery_failed), do: "Physical recovery failed or its outcome is unknown."

  defp message(:equipment_discovery_unavailable),
    do: "Equipment discovery is unavailable for the confirmed subnet."

  defp message(:remote_unavailable),
    do: "The Tailscale daemon is unavailable while remote access is enabled."

  defp message(:remote_offline), do: "Tailscale is offline while remote access is enabled."
  defp message(:remote_health), do: "Tailscale reports a health problem."
  defp message(:bus_port_unavailable), do: "An enabled bus port is missing."
end
