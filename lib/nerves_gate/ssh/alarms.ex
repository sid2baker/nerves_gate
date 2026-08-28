defmodule NervesGate.SSH.Signal.Enabled do
  @moduledoc "Immediate truthful condition indicating that Tailnet-only SSH is accepted."
  def description, do: "Tailnet-only SSH enabled"
end

defmodule NervesGate.SSH.Signal.Unavailable do
  @moduledoc "Immediate truthful condition indicating that the requested SSH listener failed."
  def description, do: "Tailnet-only SSH listener failed"
end

defmodule NervesGate.SSH.Condition.ActionableUnavailable do
  @moduledoc false
  use Alarmist.Alarm, level: :debug

  alarm_if do
    NervesGate.SSH.Signal.Enabled and
      NervesGate.SSH.Signal.Unavailable and
      not NervesGate.Storage.Signal.Failure and
      not NervesGate.DeviceState.Signal.Changing and
      not unknown_as_set(NervesGate.Commissioning.Signal.Required) and
      not NervesGate.Internet.Signal.Unavailable and
      not NervesGate.Tailnet.Signal.Unavailable
  end
end

defmodule NervesGate.SSH.Alarm.Unavailable do
  @moduledoc "Stable SSH listener failure while its Tailnet prerequisites are healthy."

  @debounce Application.compile_env(
              :nerves_gate,
              [:alarm_timings, :failure_debounce],
              30_000
            )
  use Alarmist.Alarm, level: :warning

  alarm_if do
    debounce(NervesGate.SSH.Condition.ActionableUnavailable, @debounce)
  end

  def public_id, do: "ssh_unavailable"
  def description, do: "Tailnet-only SSH unavailable"
end

defmodule NervesGate.SSH.Alarms do
  @moduledoc "Owns SSH listener signals, dependency inhibition, and accepted-state healing."

  alias NervesGate.AlarmistAdapter
  alias NervesGate.SSH
  alias NervesGate.SSH.Alarm
  alias NervesGate.SSH.Signal

  def managed_alarms do
    [NervesGate.SSH.Condition.ActionableUnavailable, Alarm.Unavailable]
  end

  def public_alarms, do: [Alarm.Unavailable]

  def alarm_levels do
    %{Signal.Enabled => :debug, Signal.Unavailable => :debug}
  end

  def remedies do
    [
      {Alarm.Unavailable, {__MODULE__, :heal, 0},
       retry_timeout: :timer.seconds(30), callback_timeout: :timer.seconds(15)}
    ]
  end

  @spec report(map()) :: :ok
  def report(%{enabled: enabled, state: state}) do
    AlarmistAdapter.report(Signal.Enabled, enabled, Signal.Enabled.description())

    AlarmistAdapter.report(
      Signal.Unavailable,
      enabled and state != :listening,
      Signal.Unavailable.description()
    )
  end

  @spec heal() :: :ok | {:error, term()}
  def heal do
    AlarmistAdapter.heal(Alarm.Unavailable, &SSH.heal/0)
  end
end
