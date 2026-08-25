defmodule NervesGate.SubnetRouter.Signal.Unavailable do
  @moduledoc "Truthful condition indicating that accepted route preferences could not be applied."
  def description, do: "Subnet router configuration could not be applied"
end

defmodule NervesGate.SubnetRouter.Condition.ActionableUnavailable do
  @moduledoc false
  use Alarmist.Alarm, level: :debug

  alarm_if do
    NervesGate.SubnetRouter.Signal.Unavailable and
      not NervesGate.Storage.Signal.Failure and
      not NervesGate.DeviceState.Signal.Changing and
      not unknown_as_set(NervesGate.Commissioning.Signal.Required) and
      not NervesGate.Internet.Signal.Unavailable and
      not NervesGate.Tailnet.Signal.Unavailable
  end
end

defmodule NervesGate.SubnetRouter.Alarm.Unavailable do
  @moduledoc "Accepted subnet routes could not be applied while Tailnet is healthy."

  @debounce Application.compile_env(
              :nerves_gate,
              [:alarm_timings, :failure_debounce],
              30_000
            )
  use Alarmist.Alarm, level: :warning

  alarm_if do
    debounce(NervesGate.SubnetRouter.Condition.ActionableUnavailable, @debounce)
  end

  def public_id, do: "subnet_router_unavailable"
  def description, do: "Subnet router configuration could not be applied"
end

defmodule NervesGate.SubnetRouter.Alarms do
  @moduledoc "Owns route-application truth, Tailnet inhibition, and accepted-state healing."

  alias NervesGate.Alarms
  alias NervesGate.SubnetRouter
  alias NervesGate.SubnetRouter.Alarm
  alias NervesGate.SubnetRouter.Signal

  def managed_alarms do
    [NervesGate.SubnetRouter.Condition.ActionableUnavailable, Alarm.Unavailable]
  end

  def public_alarms, do: [Alarm.Unavailable]
  def alarm_levels, do: %{Signal.Unavailable => :debug}

  def remedies do
    [
      {Alarm.Unavailable, {__MODULE__, :heal, 0},
       retry_timeout: :timer.minutes(1), callback_timeout: :timer.seconds(40)}
    ]
  end

  @spec failure(boolean()) :: :ok
  def failure(active) do
    Alarms.report(Signal.Unavailable, active, Signal.Unavailable.description())
  end

  @spec heal() :: :ok | {:error, term()}
  def heal do
    Alarms.heal(Alarm.Unavailable, &SubnetRouter.heal/0)
  end
end
