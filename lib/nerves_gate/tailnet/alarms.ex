defmodule NervesGate.Tailnet.Signal.Unavailable do
  @moduledoc "Immediate truthful condition indicating that Tailnet attachment is unavailable."
  def description, do: "Tailnet attachment check failed"
end

defmodule NervesGate.Tailnet.Condition.ActionableUnavailable do
  @moduledoc false
  use Alarmist.Alarm, level: :debug

  alarm_if do
    NervesGate.Tailnet.Signal.Unavailable and
      not NervesGate.Storage.Signal.Failure and
      not NervesGate.DeviceState.Signal.Changing and
      not unknown_as_set(NervesGate.Commissioning.Signal.Required) and
      not NervesGate.Internet.Signal.Unavailable
  end
end

defmodule NervesGate.Tailnet.Alarm.Unavailable do
  @moduledoc "Stable Tailnet failure while every local prerequisite is healthy."

  @debounce Application.compile_env(
              :nerves_gate,
              [:alarm_timings, :failure_debounce],
              30_000
            )
  use Alarmist.Alarm, level: :warning

  alarm_if do
    debounce(NervesGate.Tailnet.Condition.ActionableUnavailable, @debounce)
  end

  def public_id, do: "tailnet_unavailable"
  def description, do: "Tailnet unavailable"
end

defmodule NervesGate.Tailnet.Alarms do
  @moduledoc "Owns truthful Tailnet state, upstream inhibition, and non-mutating healing."

  alias NervesGate.Alarms
  alias NervesGate.Tailnet.Alarm
  alias NervesGate.Tailnet.Observer
  alias NervesGate.Tailnet.Signal

  def managed_alarms do
    [NervesGate.Tailnet.Condition.ActionableUnavailable, Alarm.Unavailable]
  end

  def public_alarms, do: [Alarm.Unavailable]
  def alarm_levels, do: %{Signal.Unavailable => :debug}

  def remedies do
    [
      {Alarm.Unavailable, {__MODULE__, :heal, 0},
       retry_timeout: :timer.minutes(1), callback_timeout: :timer.seconds(10)}
    ]
  end

  @spec report(map()) :: :ok
  def report(%{online: online}) when is_boolean(online) do
    Alarms.report(Signal.Unavailable, not online, Signal.Unavailable.description())
  end

  @spec heal() :: :ok | {:error, term()}
  def heal do
    Alarms.heal(Alarm.Unavailable, &Observer.refresh/0)
  end
end
