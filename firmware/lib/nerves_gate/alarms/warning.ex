defmodule NervesGate.Alarms.Warning do
  @moduledoc "Availability faults must persist for two seconds; recovery clears immediately."
  use Alarmist.Alarm, level: :warning, parameters: [:name, :fault]

  alarm_if do
    debounce({NervesGate.Alarms, name, fault}, 2_000)
  end
end
