defmodule NervesGate.Cluster.Signal.Enabled do
  @moduledoc "Immediate truthful condition indicating that a cluster group is accepted."
  def description, do: "Cluster mode enabled"
end

defmodule NervesGate.Cluster.Signal.Unavailable do
  @moduledoc "Immediate truthful condition indicating that local distribution is unavailable."
  def description, do: "Local cluster runtime check failed"
end

defmodule NervesGate.Cluster.Condition.ActionableUnavailable do
  @moduledoc false
  use Alarmist.Alarm, level: :debug

  alarm_if do
    NervesGate.Cluster.Signal.Enabled and
      NervesGate.Cluster.Signal.Unavailable and
      not NervesGate.Storage.Signal.Failure and
      not NervesGate.DeviceState.Signal.Changing and
      not unknown_as_set(NervesGate.Commissioning.Signal.Required) and
      not NervesGate.Internet.Signal.Unavailable and
      not NervesGate.Tailnet.Signal.Unavailable
  end
end

defmodule NervesGate.Cluster.Alarm.Unavailable do
  @moduledoc "Stable local cluster failure with all upstream layers healthy."

  @debounce Application.compile_env(
              :nerves_gate,
              [:alarm_timings, :failure_debounce],
              30_000
            )
  use Alarmist.Alarm, level: :warning

  alarm_if do
    debounce(NervesGate.Cluster.Condition.ActionableUnavailable, @debounce)
  end

  def public_id, do: "cluster_unavailable"
  def description, do: "Cluster unavailable"
end

defmodule NervesGate.Cluster.Alarms do
  @moduledoc "Owns cluster signals, dependency inhibition, and accepted-state healing."

  alias NervesGate.Alarms
  alias NervesGate.Cluster.Alarm
  alias NervesGate.Cluster.Signal
  alias NervesGate.DeviceState.Server

  def managed_alarms do
    [NervesGate.Cluster.Condition.ActionableUnavailable, Alarm.Unavailable]
  end

  def public_alarms, do: [Alarm.Unavailable]

  def alarm_levels do
    %{Signal.Enabled => :debug, Signal.Unavailable => :debug}
  end

  @remedy_options [
    retry_timeout: :timer.seconds(30),
    callback_timeout: :timer.seconds(15)
  ]
  def remedies, do: [{Alarm.Unavailable, {__MODULE__, :heal, 0}, @remedy_options}]

  @spec report(boolean(), boolean()) :: :ok
  def report(enabled, runtime_broken) do
    Alarms.report(Signal.Enabled, enabled, Signal.Enabled.description())

    Alarms.report(
      Signal.Unavailable,
      enabled and runtime_broken,
      Signal.Unavailable.description()
    )
  end

  @spec heal() :: :ok | {:error, term()}
  def heal do
    Alarms.heal(Alarm.Unavailable, fn -> Server.heal(:cluster) end)
  end
end
