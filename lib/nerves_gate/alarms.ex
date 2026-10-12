defmodule NervesGate.Alarms do
  @moduledoc """
  Shared reporting for domain-owned faults.

  * `NervesGate.Network` sets `:network_restore_failed` when saved settings
    cannot be restored and clears it after successful restoration.
  * `NervesGate.Indicators` sets `:led_restore_failed` when restoring the previous
    LED value fails and clears it after successful restoration.
  * `NervesGate.Equipment` sets `:equipment_discovery_unavailable` when passive
    discovery fails for a confirmed scope; successful observation or removal of
    the equipment configuration clears it.
  * `NervesGate.Remote` sets `:remote_unavailable` when the daemon is unavailable
    after connection was requested or observed active; daemon availability clears it.
  * `NervesGate.Buses` sets `:bus_port_unavailable` when a known enabled port is
    missing; observing its return or disabling its opt-in clears it.

  IDs are `{NervesGate.Alarms, server_name, fault}`. Unnamed instances skip global
  reports. Descriptions are fixed messages; settings and private URLs are excluded.

  Subscribe with `Alarmist.subscribe({NervesGate.Alarms, :_, :_})`, then read
  `Alarmist.get_alarms/0`. Reporting is asynchronous and repeated reports are
  deduplicated by Alarmist. Alarms retain the last reported condition; they do not
  establish current hardware readiness.
  """

  # Unknown observations leave the last report unchanged.
  @doc false
  def report(_fault, _name, nil), do: :ok
  def report(_fault, nil, _active), do: :ok

  def report(fault, name, active) do
    id = {__MODULE__, name, fault}
    event = if active, do: {:set_alarm, {id, message(fault)}}, else: {:clear_alarm, id}

    # The standard SASL events are fire-and-forget. Even a stopped alarm handler
    # must not interrupt hardware restoration or delay a trial deadline.
    if handler = Process.whereis(:alarm_handler), do: :gen_event.notify(handler, event)
    :ok
  end

  defp message(:network_restore_failed), do: "Saved network settings could not be restored."
  defp message(:led_restore_failed), do: "The run LED's previous value could not be restored."

  defp message(:equipment_discovery_unavailable),
    do: "Equipment discovery is unavailable for the confirmed subnet."

  defp message(:remote_unavailable),
    do: "The Tailscale daemon is unavailable while remote access is enabled."

  defp message(:bus_port_unavailable), do: "An enabled bus port is missing."
end
