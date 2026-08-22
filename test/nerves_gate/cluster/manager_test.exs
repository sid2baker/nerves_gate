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
    {:ok, runtime} = Agent.start_link(fn -> %{tailnet: offline(), alive: false} end)

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
      connected: fn -> [] end
    }

    name = String.to_atom("cluster_manager_#{System.unique_integer([:positive])}")
    {:ok, manager} = Manager.start_link(name: name, root: root, ops: ops, interval: 60_000)

    on_exit(fn ->
      if Process.alive?(manager), do: GenServer.stop(manager)
      File.rm_rf!(root)
    end)

    %{manager: manager, name: name, ops: ops, root: root, runtime: runtime}
  end

  test "nil cookie is truly singular and never starts distribution", %{manager: manager} do
    assert :ok = Manager.configure(nil, manager)
    assert %{enabled: false, online: false, node: nil, connected: []} = Manager.status(manager)
    refute_receive {:distribution_start, _, _}
    refute Node.alive?()
    assert Alarmist.alarm_state(Alarm.Unavailable) in [:clear, :unknown]
  end

  test "a valid cookie enables distribution without exposing the credential", context do
    %{manager: manager, root: root, runtime: runtime} = context
    cookie = "Secret_cookie-123"
    Agent.update(runtime, &%{&1 | tailnet: online()})
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "cluster")

    logs = capture_log(fn -> assert :ok = Manager.configure(cookie, manager) end)

    assert_receive {:distribution_start, "100.64.0.10", cookie_atom}
    assert cookie_atom == :"Secret_cookie-123"
    assert_receive {:cluster_changed, %{enabled: true} = status}
    assert status.enabled
    assert status.online
    assert status.connected == []
    refute inspect(status) =~ cookie
    refute inspect(:sys.get_state(manager)) =~ cookie
    refute logs =~ cookie
    assert {:ok, ^cookie} = Store.read_cluster(root)
    assert Alarmist.alarm_state(Alarm.Unavailable) in [:clear, :unknown]
  end

  test "a persisted cookie survives manager restart", context do
    %{manager: manager, name: name, ops: ops, root: root, runtime: runtime} = context
    cookie = "Restart_cookie-123"
    Agent.update(runtime, &%{&1 | tailnet: online()})
    assert :ok = Manager.configure(cookie, manager)
    assert_receive {:distribution_start, _, _}

    GenServer.stop(manager)
    Agent.update(runtime, &%{&1 | alive: false})
    {:ok, restarted} = Manager.start_link(name: name, root: root, ops: ops, interval: 60_000)
    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)

    assert_eventually(fn -> Manager.status(restarted).online end)
    assert_receive {:distribution_start, "100.64.0.10", _cookie}
    assert Manager.status(restarted).enabled
  end

  test "changing and clearing the cookie rebuilds then stops distribution", context do
    %{manager: manager, runtime: runtime} = context
    Agent.update(runtime, &%{&1 | tailnet: online()})

    assert :ok = Manager.configure("First_cookie-123", manager)
    assert_receive {:distribution_start, _, :"First_cookie-123"}

    assert :ok = Manager.configure("Second_cookie-456", manager)
    assert_receive :distribution_stop
    assert_receive {:distribution_start, _, :"Second_cookie-456"}

    assert :ok = Manager.configure(nil, manager)
    assert_receive :distribution_stop
    assert %{enabled: false, online: false, connected: []} = Manager.status(manager)
    assert {:ok, nil} = Store.read_cluster(context.root)
  end

  test "the compatibility API snapshot never exposes the configured cookie" do
    cookie = "Api_secret-cookie_123"

    try do
      assert :ok = Manager.configure(cookie)
      refute inspect(NervesGate.Status.api_snapshot()) =~ cookie
    after
      Manager.configure(nil)
    end
  end

  test "invalid cookie input never reaches persistence or atom conversion", %{
    manager: manager,
    root: root
  } do
    assert {:error, :invalid_cluster_cookie} = Manager.configure("bad cookie!", manager)
    assert {:ok, nil} = Store.read_cluster(root)
    refute_receive {:distribution_start, _, _}
  end

  defp online, do: %{online: true, ipv4: "100.64.0.10"}
  defp offline, do: %{online: false, ipv4: nil}

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
