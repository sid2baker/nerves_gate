defmodule NervesGate.Internet.Signal.Unavailable do
  @moduledoc "Immediate truthful condition indicating that Internet checks failed."
  def description, do: "Internet connectivity check failed"
end

defmodule NervesGate.Internet.Signal.UnavailableSample do
  @moduledoc "Operational Internet availability sample used only for flapping history."
  def description, do: "Operational Internet availability sample failed"
end

defmodule NervesGate.Internet.Condition.ActionableUnavailable do
  @moduledoc false
  use Alarmist.Alarm, level: :debug

  alarm_if do
    NervesGate.Internet.Signal.Unavailable and
      not NervesGate.Storage.Signal.Failure and
      not NervesGate.DeviceState.Signal.Changing and
      not unknown_as_set(NervesGate.Commissioning.Signal.Required)
  end
end

defmodule NervesGate.Internet.Alarm.Unavailable do
  @moduledoc "Stable operational alarm for unavailable Internet connectivity."

  @debounce Application.compile_env(
              :nerves_gate,
              [:alarm_timings, :failure_debounce],
              30_000
            )
  use Alarmist.Alarm, level: :warning

  alarm_if do
    debounce(NervesGate.Internet.Condition.ActionableUnavailable, @debounce)
  end

  def public_id, do: "internet_unavailable"
  def description, do: "Internet unavailable"
end

defmodule NervesGate.Internet.Alarm.Unstable do
  @moduledoc "Internet connectivity changed too frequently outside expected configuration work."
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
    hold(intensity(NervesGate.Internet.Signal.UnavailableSample, @count, @period), @hold) and
      not NervesGate.Storage.Signal.Failure and
      not NervesGate.DeviceState.Signal.Changing and
      not unknown_as_set(NervesGate.Commissioning.Signal.Required)
  end

  def public_id, do: "internet_unstable"
  def description, do: "Internet connectivity is unstable"
end

defmodule NervesGate.Internet.Alarms do
  @moduledoc "Owns truthful Internet signals, public alarms, flapping history, and healing."

  alias NervesGate.Alarms
  alias NervesGate.Internet
  alias NervesGate.Internet.Alarm
  alias NervesGate.Internet.Signal

  def managed_alarms do
    [
      NervesGate.Internet.Condition.ActionableUnavailable,
      Alarm.Unavailable,
      Alarm.Unstable
    ]
  end

  def public_alarms, do: [Alarm.Unavailable, Alarm.Unstable]

  def alarm_levels do
    %{Signal.Unavailable => :debug, Signal.UnavailableSample => :debug}
  end

  def remedies do
    [
      {Alarm.Unavailable, {__MODULE__, :heal, 0},
       retry_timeout: :timer.minutes(1), callback_timeout: :timer.seconds(20)}
    ]
  end

  @spec report(map(), map() | nil) :: :ok
  def report(%{online: online}, previous \\ nil) when is_boolean(online) do
    Alarms.report(Signal.Unavailable, not online, Signal.Unavailable.description())

    if availability_changed?(previous, online) and Alarms.operational_monitoring?() do
      Alarms.report(
        Signal.UnavailableSample,
        not online,
        Signal.UnavailableSample.description()
      )
    end

    :ok
  end

  @spec heal() :: :ok | {:error, term()}
  def heal do
    Alarms.heal(Alarm.Unavailable, fn ->
      case Internet.status() do
        %{reason: :no_carrier} ->
          Internet.poll_now()
          {:error, :physical_link_down}

        %{reason: :not_configured} ->
          {:error, :not_configured}

        _status ->
          Internet.heal()
      end
    end)
  end

  defp availability_changed?(%{online: previous}, online) when is_boolean(previous),
    do: previous != online

  defp availability_changed?(_previous, _online), do: false
end
