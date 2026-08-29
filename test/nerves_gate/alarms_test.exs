defmodule NervesGate.AlarmsTest do
  use ExUnit.Case, async: true

  alias NervesGate.Alarms
  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.{Server, State}

  setup do
    owner = self()
    alarm_name = String.to_atom("alarms_#{System.unique_integer([:positive])}")

    owners =
      Map.new(State.sources() -- [:device], fn source ->
        {source, if(source == :alarms, do: alarm_name, else: owner)}
      end)

    {:ok, server} =
      Server.start_link(
        name: nil,
        boot_id: "boot-a",
        device: %{device_id: "gate-a", name: "Gate A", firmware_version: "1.0.0"},
        owners: owners,
        heartbeat_interval: 60_000
      )

    {:ok, alarms} =
      Alarms.start_link(
        name: alarm_name,
        device_state: server,
        timings: %{
          failure_debounce: 10,
          flapping_count: 4,
          flapping_period: 500,
          flapping_hold: 100
        }
      )

    %{server: server, alarms: alarms}
  end

  test "one module owns the complete stable alarm catalogue", context do
    assert Alarms.public_ids() == [
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

    report(context, :configuration, %{configured: false, pending: nil})
    report(context, :commissioning, commissioning(:active))

    assert_eventually(fn -> alarm_ids(context) == ["commissioning_required"] end)
    assert Server.state(context.server).alarms == Alarms.active(context.alarms)
  end

  test "commissioning alarms are mutually exclusive", context do
    report(context, :configuration, %{configured: false, pending: nil})
    report(context, :commissioning, commissioning(:waiting))
    assert_eventually(fn -> alarm_ids(context) == ["commissioning_unavailable"] end)

    report(context, :commissioning, commissioning(:active))
    assert_eventually(fn -> alarm_ids(context) == ["commissioning_required"] end)
  end

  test "storage failure is sticky private evidence and suppresses dependent alarms", context do
    configure_operational(context)
    report(context, :internet, internet(false))
    assert_eventually(fn -> "internet_unavailable" in alarm_ids(context) end)

    assert :ok = Alarms.storage_failure(true, context.alarms)
    assert_eventually(fn -> alarm_ids(context) == ["storage_failure"] end)

    assert :ok = Alarms.storage_failure(false, context.alarms)
    assert_eventually(fn -> "internet_unavailable" in alarm_ids(context) end)
  end

  test "candidate work inhibits expected connectivity alarms", context do
    configure_operational(context)
    report(context, :internet, internet(false))
    assert_eventually(fn -> "internet_unavailable" in alarm_ids(context) end)

    report(context, :configuration, %{configured: true, pending: %{id: "candidate"}})
    assert_eventually(fn -> alarm_ids(context) == [] end)
  end

  defp configure_operational(context) do
    report(context, :configuration, %{configured: true, pending: nil})
    report(context, :commissioning, commissioning(:disabled))
  end

  defp report(context, source, value) do
    assert :ok = DeviceState.publish({:state_reported, source, value}, context.server)
  end

  defp alarm_ids(context), do: Enum.map(Alarms.active(context.alarms), & &1.id)

  defp commissioning(state) do
    %NervesGate.Commissioning.Status{
      state: state,
      active: [],
      mode: if(state == :disabled, do: :disabled, else: :commissioning)
    }
  end

  defp internet(online) do
    %NervesGate.Internet.Status{
      state: if(online, do: :online, else: :offline),
      interface: "eth0",
      online: online,
      ready: online,
      reason: if(online, do: nil, else: :offline),
      checks: %{}
    }
  end

  defp assert_eventually(predicate, attempts \\ 100) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not converge")

      true ->
        Process.sleep(5)
        assert_eventually(predicate, attempts - 1)
    end
  end
end
