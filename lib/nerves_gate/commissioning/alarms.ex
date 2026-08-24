defmodule NervesGate.Commissioning.Signal.Required do
  @moduledoc "Raw condition indicating that accepted gateway settings are incomplete."
  def description, do: "Device commissioning is required"
end

defmodule NervesGate.Commissioning.Signal.AccessUnavailable do
  @moduledoc "Raw condition indicating that requested local commissioning access is unavailable."
  def description, do: "No local commissioning interface is available"
end

defmodule NervesGate.Commissioning.Alarm.Required do
  @moduledoc "The device needs local commissioning and local access is available."
  use Alarmist.Alarm, level: :warning

  alarm_if do
    NervesGate.Commissioning.Signal.Required and
      not NervesGate.Commissioning.Signal.AccessUnavailable and
      not NervesGate.Storage.Signal.Failure
  end

  def public_id, do: "commissioning_required"
  def description, do: "Device commissioning is required"
end

defmodule NervesGate.Commissioning.Alarm.Unavailable do
  @moduledoc "Commissioning is required but no local interface could be enabled."

  use Alarmist.Alarm, level: :error

  alarm_if do
    NervesGate.Commissioning.Signal.Required and
      NervesGate.Commissioning.Signal.AccessUnavailable and
      not NervesGate.Storage.Signal.Failure
  end

  def public_id, do: "commissioning_unavailable"
  def description, do: "No local commissioning interface is available"
end

defmodule NervesGate.Commissioning.Alarms do
  @moduledoc "Owns commissioning signals, mutually exclusive public alarms, and access healing."

  alias NervesGate.Alarms
  alias NervesGate.Commissioning.Access
  alias NervesGate.Commissioning.Alarm
  alias NervesGate.Commissioning.Signal

  def managed_alarms, do: [Alarm.Required, Alarm.Unavailable]
  def public_alarms, do: [Alarm.Required, Alarm.Unavailable]

  def alarm_levels do
    %{Signal.Required => :debug, Signal.AccessUnavailable => :debug}
  end

  def remedies do
    [
      {Alarm.Unavailable, {__MODULE__, :heal, 0},
       retry_timeout: :timer.minutes(1), callback_timeout: :timer.seconds(15)}
    ]
  end

  @spec required(boolean()) :: :ok
  def required(active) do
    Alarms.report_sync(Signal.Required, active, Signal.Required.description())
  end

  @spec unavailable(boolean()) :: :ok
  def unavailable(active) do
    Alarms.report_sync(
      Signal.AccessUnavailable,
      active,
      Signal.AccessUnavailable.description()
    )
  end

  @spec heal() :: :ok | {:error, term()}
  def heal do
    Alarms.heal(Alarm.Unavailable, &Access.heal/0)
  end
end
