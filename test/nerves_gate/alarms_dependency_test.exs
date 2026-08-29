defmodule NervesGate.AlarmsDependencyTest do
  use ExUnit.Case, async: true

  alias NervesGate.Alarms
  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.{Server, State}

  setup do
    owner = self()
    alarm_name = String.to_atom("alarm_policy_#{System.unique_integer([:positive])}")

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

    context = %{server: server, alarms: alarms}
    report(context, :configuration, %{configured: true, pending: nil})
    report(context, :commissioning, commissioning())
    context
  end

  test "the first unhealthy dependency owns the actionable alarm", context do
    report(context, :internet, internet(false))
    report(context, :tailnet, tailnet(false))

    assert_eventually(fn -> alarm_ids(context) == ["internet_unavailable"] end)

    report(context, :internet, internet(true))
    assert_eventually(fn -> alarm_ids(context) == ["tailnet_unavailable"] end)

    report(context, :tailnet, tailnet(true))
    assert_eventually(fn -> alarm_ids(context) == [] end)
  end

  test "downstream failures appear only while Internet and Tailnet are healthy", context do
    report(context, :internet, internet(true))
    report(context, :tailnet, tailnet(true))
    report(context, :cluster, cluster(true, false))
    report(context, :ssh, ssh(true, :backoff))
    report(context, :subnet_router, subnet_router(true, :backoff))

    assert_eventually(fn ->
      alarm_ids(context) == [
        "cluster_unavailable",
        "ssh_unavailable",
        "subnet_router_unavailable"
      ]
    end)

    report(context, :tailnet, tailnet(false))
    assert_eventually(fn -> alarm_ids(context) == ["tailnet_unavailable"] end)
  end

  test "repeated operational Internet transitions produce one bounded unstable alarm", context do
    report(context, :tailnet, tailnet(true))

    Enum.each([true, false, true, false, true], fn online ->
      report(context, :internet, internet(online))

      assert_eventually(fn ->
        :sys.get_state(context.alarms).client.state.internet.online == online
      end)
    end)

    assert_eventually(fn -> "internet_unstable" in alarm_ids(context) end)
    Process.sleep(120)
    send(context.alarms, :tick)
    assert_eventually(fn -> "internet_unstable" not in alarm_ids(context) end)
  end

  defp report(context, source, value) do
    assert :ok = DeviceState.publish({:state_reported, source, value}, context.server)
  end

  defp alarm_ids(context), do: Enum.map(Alarms.active(context.alarms), & &1.id)

  defp commissioning do
    %NervesGate.Commissioning.Status{state: :disabled, active: [], mode: :disabled}
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

  defp tailnet(online) do
    %NervesGate.Tailnet.Status{
      state: if(online, do: :online, else: :connecting),
      online: online,
      authenticated: online,
      hostname: if(online, do: "gate-a"),
      ipv4: if(online, do: "100.64.0.10"),
      peers: [],
      nodes: [],
      subnet_router: %{},
      health: %{},
      error: if(online, do: nil, else: :offline)
    }
  end

  defp cluster(enabled, online) do
    %NervesGate.Cluster.Status{
      state: if(online, do: :online, else: :backoff),
      enabled: enabled,
      group: if(enabled, do: "factory"),
      online: online,
      node: nil,
      connected: [],
      candidates: [],
      groups: []
    }
  end

  defp ssh(enabled, state) do
    %NervesGate.SSH.Status{enabled: enabled, state: state, address: nil, port: 22}
  end

  defp subnet_router(enabled, state) do
    %NervesGate.SubnetRouter.Status{
      enabled: enabled,
      routes: if(enabled, do: ["192.168.1.0/24"], else: []),
      state: state,
      observed: %{}
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
