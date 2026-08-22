defmodule NervesGate.Tailnet.Signal.Unavailable do
  @moduledoc "Immediate raw condition indicating that the local Tailnet attachment is unavailable."
  def description, do: "Tailnet attachment check failed"
end

defmodule NervesGate.Tailnet.Condition.ActionableUnavailable do
  @moduledoc false
  use Alarmist.Alarm, level: :debug

  alarm_if do
    NervesGate.Tailnet.Signal.Unavailable and
      not NervesGate.Settings.Signal.TailnetChanging and
      not NervesGate.Internet.Signal.Unavailable and
      not NervesGate.Commissioning.Alarm.Required
  end
end

defmodule NervesGate.Tailnet.Alarm.Unavailable do
  @moduledoc "Stable Tailnet failure after Internet connectivity has been established."
  use Alarmist.Alarm, level: :warning

  @debounce Application.compile_env(
              :nerves_gate,
              [:alarm_timings, :failure_debounce],
              30_000
            )

  alarm_if do
    debounce(NervesGate.Tailnet.Condition.ActionableUnavailable, @debounce)
  end

  def description, do: "Tailnet unavailable"
end

defmodule NervesGate.Tailnet.Alarms do
  @moduledoc "Owns translation from immediate Tailnet health to raw conditions."

  alias NervesGate.Alarms
  alias NervesGate.Settings.Maintenance
  alias NervesGate.Tailnet.Signal

  @spec report(map()) :: :ok
  def report(%{online: online}) do
    unless Maintenance.active?(:tailnet) do
      Alarms.toggle(Signal.Unavailable, not online, Signal.Unavailable.description())
    end

    :ok
  end
end
