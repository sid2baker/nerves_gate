defmodule NervesGate.TestAlarm.Public do
  def description, do: "Public test alarm"
end

defmodule NervesGate.AlarmsReporterTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias NervesGate.Alarms.Reporter
  alias NervesGate.Internet.Alarm.Unavailable
  alias NervesGate.TestAlarm.Public

  test "public alarm transitions flow into authoritative device state" do
    NervesGate.Alarms.set(Public, Public.description())

    assert_eventually(fn ->
      Enum.any?(NervesGate.DeviceState.Server.data().alarms, &(&1.id == inspect(Public)))
    end)

    NervesGate.Alarms.clear(Public)

    assert_eventually(fn ->
      Enum.all?(NervesGate.DeviceState.Server.data().alarms, &(&1.id != inspect(Public)))
    end)
  end

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

    assert {:set, public_alarm} = NervesGate.Alarms.public_event(event)
    refute inspect(public_alarm) =~ credential

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

  defp assert_eventually(predicate, attempts \\ 50) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("alarm state did not reach DeviceState")

      true ->
        Process.sleep(10)
        assert_eventually(predicate, attempts - 1)
    end
  end
end
