defmodule NervesGate.Cluster.Signal.Enabled do
  @moduledoc "Immediate internal condition indicating that a cluster cookie is configured."
  def description, do: "Cluster mode enabled"
end

defmodule NervesGate.Cluster.Signal.Unavailable do
  @moduledoc "Immediate raw condition indicating that local distributed Erlang is broken."
  def description, do: "Local cluster runtime check failed"
end

defmodule NervesGate.Cluster.Condition.ActionableUnavailable do
  @moduledoc false
  use Alarmist.Alarm, level: :debug

  alarm_if do
    NervesGate.Cluster.Signal.Enabled and
      NervesGate.Cluster.Signal.Unavailable and
      not NervesGate.Internet.Signal.Unavailable and
      not NervesGate.Tailnet.Signal.Unavailable and
      not NervesGate.Commissioning.Alarm.Required
  end
end

defmodule NervesGate.Cluster.Alarm.Unavailable do
  @moduledoc "Stable failure of an enabled local cluster runtime with all prerequisites available."
  use Alarmist.Alarm, level: :warning

  @debounce Application.compile_env(
              :nerves_gate,
              [:alarm_timings, :failure_debounce],
              30_000
            )

  alarm_if do
    debounce(NervesGate.Cluster.Condition.ActionableUnavailable, @debounce)
  end

  def description, do: "Cluster unavailable"
end

defmodule NervesGate.Cluster.Alarms do
  @moduledoc "Owns the immediate enabled and local-runtime cluster conditions."

  alias NervesGate.Alarms
  alias NervesGate.Cluster.Signal

  @spec report(boolean(), boolean()) :: :ok
  def report(enabled, runtime_broken) do
    Alarms.toggle(Signal.Enabled, enabled, Signal.Enabled.description())

    Alarms.toggle(
      Signal.Unavailable,
      enabled and runtime_broken,
      Signal.Unavailable.description()
    )
  end
end
