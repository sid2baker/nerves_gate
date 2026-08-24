defmodule NervesGate.Storage.Signal.Failure do
  @moduledoc "Raw sticky condition indicating unavailable or corrupt persistent storage."
  def description, do: "Persistent storage is unavailable or corrupt"
end

defmodule NervesGate.Storage.Alarm.Failure do
  @moduledoc "Persistent storage requires non-local inspection or repair."
  use Alarmist.Alarm, level: :error

  alarm_if do
    NervesGate.Storage.Signal.Failure
  end

  def public_id, do: "storage_failure"
  def description, do: "Persistent storage is unavailable or corrupt"
end

defmodule NervesGate.Storage.Alarms do
  @moduledoc "Owns the sticky storage signal and non-healable public alarm."

  alias NervesGate.Alarms
  alias NervesGate.Storage.Alarm
  alias NervesGate.Storage.Signal

  def managed_alarms, do: [Alarm.Failure]
  def public_alarms, do: [Alarm.Failure]
  def alarm_levels, do: %{Signal.Failure => :debug}
  def remedies, do: []

  @spec failure(boolean()) :: :ok
  def failure(active) do
    Alarms.report_sync(Signal.Failure, active, Signal.Failure.description())
  end
end
