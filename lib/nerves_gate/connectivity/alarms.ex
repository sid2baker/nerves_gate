defmodule NervesGate.Connectivity.Alarms do
  @moduledoc """
  Scoped Alarmist conditions. Raw expected/online inputs are observations, not
  configuration stores. The managed condition survives agent/sensor restarts;
  reading it after subscribing recovers a missed transition.
  """
  alias __MODULE__.{InternetExpected, InternetOnline, InternetUnavailable, ObservationUnavailable}

  def start(scope), do: Alarmist.add_managed_alarm({InternetUnavailable, scope})

  def subscribe(scope) do
    Alarmist.unsubscribe({InternetUnavailable, scope})
    Alarmist.subscribe({InternetUnavailable, scope})
  end

  def update(scope, %{expected: expected, online: online}) do
    input(ObservationUnavailable, scope, false)
    input(InternetOnline, scope, online)
    input(InternetExpected, scope, expected)
  end

  def update(scope, :unavailable), do: input(ObservationUnavailable, scope, true)

  def condition(scope) do
    case PropertyTable.fetch_with_timestamp(Alarmist, {InternetUnavailable, scope}) do
      {:ok, {state, _, _}, timestamp} -> {state, timestamp}
      :error -> {:unknown, nil}
    end
  end

  def stop(scope) do
    :ok = Alarmist.remove_managed_alarm({InternetUnavailable, scope})

    for alarm <- [InternetExpected, InternetOnline, ObservationUnavailable, InternetUnavailable],
        do: :alarm_handler.clear_alarm({alarm, scope})

    :ok
  end

  defp input(alarm, scope, true), do: :alarm_handler.set_alarm({{alarm, scope}, nil})
  defp input(alarm, scope, false), do: :alarm_handler.clear_alarm({alarm, scope})
end

defmodule NervesGate.Connectivity.Alarms.InternetUnavailable do
  @moduledoc "Loss of expected Internet connectivity, or an unavailable observation source."
  use Alarmist.Alarm, parameters: [:scope], level: :warning
  alias NervesGate.Connectivity.Alarms.{InternetExpected, InternetOnline, ObservationUnavailable}

  alarm_if do
    ({InternetExpected, scope} and not {InternetOnline, scope}) or {ObservationUnavailable, scope}
  end
end
