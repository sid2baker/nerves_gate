defmodule NervesGate.AlarmsReporterTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias NervesGate.Alarms.Reporter
  alias NervesGate.Internet.Alarm.Unavailable

  test "alarm transitions use structured Logger metadata without caller descriptions" do
    credential = "Never_log_this_cookie-123"

    event = %Alarmist.Event{
      id: Unavailable,
      state: :set,
      description: credential,
      level: :warning,
      timestamp: System.monotonic_time(),
      previous_state: :clear,
      previous_timestamp: System.monotonic_time()
    }

    log =
      capture_log(
        [
          format: "$metadata$message",
          metadata: [:alarm, :alarm_id, :alarm_state, :alarm_level, :alarm_description]
        ],
        fn -> Reporter.log_transition(event) end
      )

    assert log =~ "alarm=true"
    assert log =~ "alarm_state=set"
    assert log =~ "alarm set: #{inspect(Unavailable)}"
    assert log =~ "Internet unavailable"
    refute log =~ credential
  end
end
