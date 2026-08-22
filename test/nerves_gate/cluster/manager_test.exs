defmodule NervesGate.Cluster.ManagerTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias NervesGate.Cluster.Alarm
  alias NervesGate.Cluster.Manager
  alias NervesGate.Store
  alias NervesGate.TestScenario

  setup do
    root = TestScenario.temporary_root(:cluster_manager)
    :ok = Store.initialize(root)
    owner = self()

    {:ok, runtime} =
      Agent.start_link(fn -> %{tailnet: offline(), alive: false, connected: []} end)

    ops = %{
      tail_status: fn -> Agent.get(runtime, & &1.tailnet) end,
      start: fn ipv4, cookie ->
        send(owner, {:distribution_start, ipv4, cookie})
        Agent.update(runtime, &%{&1 | alive: true})
        {:ok, :"nervesgate@100.64.0.10"}
      end,
      stop: fn ->
        send(owner, :distribution_stop)
        Agent.update(runtime, &%{&1 | alive: false})
        :ok
      end,
      alive?: fn -> Agent.get(runtime, & &1.alive) end,
      connect: fn ipv4 ->
        node = String.to_atom("nervesgate@#{ipv4}")
        send(owner, {:distribution_connect, ipv4})
        Agent.update(runtime, &%{&1 | connected: Enum.uniq([node | &1.connected])})
        {:ok, node}
      end,
      connected: fn -> Agent.get(runtime, & &1.connected) end,
      discover: fn ipv4 ->
        send(owner, {:group_discovery, ipv4})
        {:ok, "Shared_group"}
      end
    }

    name = String.to_atom("cluster_manager_#{System.unique_integer([:positive])}")
    {:ok, manager} = Manager.start_link(name: name, root: root, ops: ops, interval: 60_000)

    on_exit(fn ->
      if Process.alive?(manager), do: GenServer.stop(manager)
      File.rm_rf!(root)
    end)

    %{manager: manager, name: name, ops: ops, root: root, runtime: runtime}
  end

  test "nil group is truly singular and never starts distribution", %{manager: manager} do
    assert :ok = Manager.configure(nil, manager)
    assert %{enabled: false, online: false, node: nil, connected: []} = Manager.status(manager)
    refute_receive {:distribution_start, _, _}
    refute Node.alive?()
    assert Alarmist.alarm_state(Alarm.Unavailable) in [:clear, :unknown]
  end

  test "a public group enables distribution and is exposed in status", context do
    %{manager: manager, root: root, runtime: runtime} = context
    group = "Plant_floor"
    Agent.update(runtime, &%{&1 | tailnet: online()})
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "cluster")

    logs = capture_log(fn -> assert :ok = Manager.configure(group, manager) end)

    assert_receive {:distribution_start, "100.64.0.10", group_atom}
    assert group_atom == :Plant_floor
    assert_receive {:cluster_changed, %{enabled: true} = status}
    assert status.enabled
    assert status.online
    assert status.group == group
    assert status.connected == []
    assert inspect(status) =~ group
    assert inspect(:sys.get_state(manager)) =~ group
    refute logs =~ "distribution_start_failed"
    assert {:ok, ^group} = Store.read_cluster(root)
    assert Alarmist.alarm_state(Alarm.Unavailable) in [:clear, :unknown]
  end

  test "visible NervesGate peers are connected automatically", context do
    %{manager: manager, runtime: runtime} = context
    Agent.update(runtime, &%{&1 | tailnet: online_with_peers()})

    assert :ok = Manager.configure("Shared_group", manager)
    assert_receive {:distribution_start, "100.64.0.10", _cookie}
    assert Manager.status(manager).candidates != []
    assert_receive {:group_discovery, "100.64.0.11"}, 1_000
    assert_receive {:group_discovery, "100.64.0.12"}, 1_000
    assert_receive {:distribution_connect, "100.64.0.11"}, 1_000
    assert_receive {:distribution_connect, "100.64.0.12"}, 1_000

    assert_eventually(fn ->
      Manager.status(manager).candidates |> Enum.all?(& &1.connected)
    end)

    assert %{connected: connected} = Manager.status(manager)

    assert Enum.sort(connected) == [
             :"nervesgate@100.64.0.11",
             :"nervesgate@100.64.0.12"
           ]

    refute_receive {:distribution_connect, _ipv4}
  end

  test "gateways in other public groups are listed but not connected", context do
    %{manager: manager, runtime: runtime} = context
    Agent.update(runtime, &%{&1 | tailnet: online_with_peers()})

    assert :ok = Manager.configure("Different_group", manager)
    assert_receive {:group_discovery, "100.64.0.11"}, 1_000
    assert_receive {:group_discovery, "100.64.0.12"}, 1_000

    assert_eventually(fn ->
      Manager.status(manager).groups |> Enum.any?(&(&1.name == "Shared_group"))
    end)

    refute_receive {:distribution_connect, _ipv4}, 100
    assert Manager.status(manager).connected == []
  end

  test "a persisted group survives manager restart", context do
    %{manager: manager, name: name, ops: ops, root: root, runtime: runtime} = context
    group = "Restart_group"
    Agent.update(runtime, &%{&1 | tailnet: online()})
    assert :ok = Manager.configure(group, manager)
    assert_receive {:distribution_start, _, _}

    GenServer.stop(manager)
    Agent.update(runtime, &%{&1 | alive: false})
    {:ok, restarted} = Manager.start_link(name: name, root: root, ops: ops, interval: 60_000)
    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)

    assert_eventually(fn -> Manager.status(restarted).online end)
    assert_receive {:distribution_start, "100.64.0.10", _cookie}
    assert Manager.status(restarted).enabled
  end

  test "changing and clearing the group rebuilds then stops distribution", context do
    %{manager: manager, runtime: runtime} = context
    Agent.update(runtime, &%{&1 | tailnet: online()})

    assert :ok = Manager.configure("First_group", manager)
    assert_receive {:distribution_start, _, :First_group}

    assert :ok = Manager.configure("Second_group", manager)
    assert_receive :distribution_stop
    assert_receive {:distribution_start, _, :Second_group}

    assert :ok = Manager.configure(nil, manager)
    assert_receive :distribution_stop
    assert %{enabled: false, online: false, connected: []} = Manager.status(manager)
    assert {:ok, nil} = Store.read_cluster(context.root)
  end

  test "a staged group is temporary until confirmed or rolled back", context do
    %{manager: manager, runtime: runtime, root: root} = context
    Agent.update(runtime, &%{&1 | tailnet: online()})
    assert :ok = Manager.configure("Original_group", manager)
    assert_receive {:distribution_start, _, :Original_group}

    assert {:ok, pending} = Manager.stage("Candidate_group", "connection-a", manager)
    assert_receive :distribution_stop
    assert_receive {:distribution_start, _, :Candidate_group}
    assert Manager.status(manager).group == "Candidate_group"
    assert {:ok, "Original_group"} = Store.read_cluster(root)

    assert :ok = Manager.revert(pending.id, manager)
    assert_receive :distribution_stop
    assert_receive {:distribution_start, _, :Original_group}
    assert Manager.status(manager).group == "Original_group"

    assert {:ok, pending} = Manager.stage("Candidate_group", "connection-a", manager)

    assert {:error, :fresh_connection_required} =
             Manager.confirm(pending.id, "connection-a", manager)

    assert :ok = Manager.confirm(pending.id, "connection-b", manager)
    assert {:ok, "Candidate_group"} = Store.read_cluster(root)
  end

  test "the compatibility API snapshot exposes the configured public group" do
    group = "Api_public_group"

    try do
      assert :ok = Manager.configure(group)
      assert inspect(NervesGate.Status.api_snapshot()) =~ group
    after
      Manager.configure(nil)
    end
  end

  test "invalid group input never reaches persistence or atom conversion", %{
    manager: manager,
    root: root
  } do
    assert {:error, :invalid_cluster_group} = Manager.configure("bad group!", manager)
    assert {:ok, nil} = Store.read_cluster(root)
    refute_receive {:distribution_start, _, _}
  end

  defp online, do: %{online: true, ipv4: "100.64.0.10", nodes: []}

  defp online_with_peers do
    %{
      online: true,
      ipv4: "100.64.0.10",
      nodes: [
        %{hostname: "nervesgate-m01", ipv4: "100.64.0.10", online: true, self: true},
        %{hostname: "nervesgate-m02", ipv4: "100.64.0.11", online: true, self: false},
        %{hostname: "nervesgate-m03", ipv4: "100.64.0.12", online: true, self: false},
        %{hostname: "laptop", ipv4: "100.64.0.20", online: true, self: false}
      ]
    }
  end

  defp offline, do: %{online: false, ipv4: nil, nodes: []}

  defp assert_eventually(predicate, attempts \\ 50) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not become true")

      true ->
        Process.sleep(10)
        assert_eventually(predicate, attempts - 1)
    end
  end
end
