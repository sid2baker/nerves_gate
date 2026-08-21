defmodule NervesGate.Internet.Signal.Unavailable do
  @moduledoc "Immediate raw condition indicating that Internet checks failed."
  def description, do: "Internet connectivity check failed"
end

defmodule NervesGate.Internet.Condition.ActionableUnavailable do
  @moduledoc false
  use Alarmist.Alarm, level: :debug

  alarm_if do
    NervesGate.Internet.Signal.Unavailable and
      not NervesGate.Commissioning.Alarm.Required
  end
end

defmodule NervesGate.Internet.Alarm.Unavailable do
  @moduledoc "Stable operational alarm for unavailable Internet connectivity."
  use Alarmist.Alarm, level: :warning

  @debounce Application.compile_env(
              :nerves_gate,
              [:alarm_timings, :failure_debounce],
              30_000
            )

  alarm_if do
    debounce(NervesGate.Internet.Condition.ActionableUnavailable, @debounce)
  end

  def description, do: "Internet unavailable"
end

defmodule NervesGate.Internet.Alarm.Unstable do
  @moduledoc "Internet connectivity changed too frequently."
  use Alarmist.Alarm, level: :warning

  @count Application.compile_env(:nerves_gate, [:alarm_timings, :flapping_count], 4)
  @period Application.compile_env(
            :nerves_gate,
            [:alarm_timings, :flapping_period],
            :timer.minutes(5)
          )
  @hold Application.compile_env(
          :nerves_gate,
          [:alarm_timings, :flapping_hold],
          :timer.minutes(10)
        )

  alarm_if do
    hold(intensity(NervesGate.Internet.Signal.Unavailable, @count, @period), @hold) and
      not NervesGate.Commissioning.Alarm.Required
  end

  def description, do: "Internet connectivity is unstable"
end

defmodule NervesGate.Internet.Alarms do
  @moduledoc "Owns translation from immediate Internet health to raw conditions."

  alias NervesGate.Alarms
  alias NervesGate.Internet.Signal

  @spec report(map()) :: :ok
  def report(%{online: online}) do
    Alarms.toggle(Signal.Unavailable, not online, Signal.Unavailable.description())
  end
end
