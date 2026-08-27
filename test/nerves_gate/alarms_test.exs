defmodule NervesGate.TestAlarm.Uncatalogued do
  @moduledoc false
  def description, do: "Uncatalogued test alarm"
end

defmodule NervesGate.AlarmsTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias NervesGate.Alarms
  alias NervesGate.Internet.Alarm.Unavailable
  alias NervesGate.Storage.Signal.Failure, as: StorageFailure
  alias NervesGate.TestAlarm.Uncatalogued

  test "subsystems declare the complete stable public alarm contract" do
    assert Alarms.public_ids() |> Enum.map(& &1.public_id()) |> Enum.sort() == [
             "cluster_unavailable",
             "commissioning_required",
             "commissioning_unavailable",
             "internet_unavailable",
             "internet_unstable",
             "ssh_unavailable",
             "storage_failure",
             "subnet_router_unavailable",
             "tailnet_unavailable"
           ]
  end

  test "subsystem-declared public alarm transitions flow into authoritative device state" do
    Alarms.clear(StorageFailure)
    on_exit(fn -> Alarms.clear(StorageFailure) end)
    assert_eventually(fn -> public_alarm_absent?("storage_failure") end)

    Alarms.set(StorageFailure, StorageFailure.description())
    assert_eventually(fn -> public_alarm_present?("storage_failure") end)

    Alarms.clear(StorageFailure)
    assert_eventually(fn -> public_alarm_absent?("storage_failure") end)
  end

  test "uncatalogued alarms never become public" do
    Alarms.set(Uncatalogued, Uncatalogued.description())
    on_exit(fn -> Alarms.clear(Uncatalogued) end)

    refute Enum.any?(Alarms.active(), &(&1.id == inspect(Uncatalogued)))

    event = alarm_event({Uncatalogued, "Never_publish_this_parameter-123"}, :set, :error)
    assert Alarms.public_event(event) == :ignore
    log = capture_log(fn -> Alarms.log_transition(event) end)
    refute log =~ "Uncatalogued"
    refute log =~ "Never_publish_this_parameter-123"
  end

  test "public alarm logs use stable catalogue metadata without caller descriptions" do
    credential = "Never_log_this_cookie-123"
    event = %{alarm_event(Unavailable, :set, :warning) | description: credential}

    assert {:set, public_alarm} = Alarms.public_event(event)
    assert public_alarm.id == "internet_unavailable"
    refute inspect(public_alarm) =~ credential

    log =
      capture_log(
        [
          format: "$metadata$message",
          metadata: [:alarm, :alarm_id, :alarm_state, :alarm_level, :alarm_description]
        ],
        fn -> Alarms.log_transition(event) end
      )

    assert log =~ "alarm=true"
    assert log =~ "alarm_id=internet_unavailable"
    assert log =~ "alarm_state=set"
    assert log =~ "alarm set: internet_unavailable"
    assert log =~ "Internet unavailable"
    refute log =~ credential
  end

  defp alarm_event(id, state, level) do
    %Alarmist.Event{
      id: id,
      state: state,
      description: "ignored",
      level: level,
      timestamp: System.monotonic_time(),
      previous_state: :clear,
      previous_timestamp: System.monotonic_time()
    }
  end

  defp public_alarm_present?(id) do
    Enum.any?(NervesGate.DeviceState.Server.state().alarms, &(&1.id == id))
  end

  defp public_alarm_absent?(id) do
    Enum.all?(NervesGate.DeviceState.Server.state().alarms, &(&1.id != id))
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
