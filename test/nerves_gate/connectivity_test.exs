defmodule NervesGate.ConnectivityTest do
  use ExUnit.Case, async: false
  alias NervesGate.{Config, Connectivity, Network, Remote}
  alias NervesGate.Connectivity.{Alarms, Plugin, Signals}
  alias NervesGate.Network.Host
  @moduletag :tmp_dir
  @network __MODULE__.NetworkServer
  @remote __MODULE__.RemoteServer
  @control __MODULE__.Control
  @wan %{
    "mode" => "ports",
    "eth0" => %{"role" => "internet", "address" => Config.address_defaults()},
    "eth1" => nil
  }

  defmodule Probe do
    @behaviour NervesGate.Connectivity.Probe
    def read(network, remote) do
      controls =
        Agent.get_and_update(NervesGate.ConnectivityTest.Control, fn s ->
          {s, %{s | count: s.count + 1}}
        end)

      send(controls.owner, {:recheck, self()})
      if controls.hold, do: receive(do: (:release -> :ok))
      NervesGate.Connectivity.Probe.read(network, remote)
    end
  end

  setup %{tmp_dir: dir} do
    host = start_supervised!({Host, name: nil})
    remote_host = start_supervised!({Remote.Host, name: nil})
    path = Path.join(dir, "config.json")
    :ok = Config.save(%{Config.defaults() | "setup_completed" => true, "network" => @wan}, path)

    start_supervised!(
      {Network, name: @network, path: path, adapter: {Host, host}, poll_ms: 60_000}
    )

    start_supervised!(
      {Remote, name: @remote, adapter: {Remote.Host, remote_host}, poll_ms: 60_000}
    )

    owner = self()

    start_supervised!(%{
      id: @control,
      start:
        {Agent, :start_link, [fn -> %{owner: owner, hold: false, count: 0} end, [name: @control]]}
    })

    scope = NervesGate.Command.id()

    opts = [
      name: nil,
      monitoring: %{
        scope: scope,
        network: @network,
        remote: @remote,
        probe: Probe,
        retry_ms: 30,
        timeout: 150
      }
    ]

    on_exit(fn -> Alarms.stop(scope) end)
    %{host: host, scope: scope, opts: opts, path: path}
  end

  test "pure routes reject duplicate conditions, stale timers and duplicate completions" do
    agent = Connectivity.Agent.new!(state: %{monitoring: %{}})
    lost = Signals.new("connectivity.lost", %{revision: 10})

    assert {:ok, agent, [_, %Jido.Plugin.Scheduler.Schedule{}]} =
             Connectivity.Agent.cmd(agent, lost)

    assert {:ok, ^agent, []} = Connectivity.Agent.cmd(agent, lost)

    assert {:ok, ^agent, []} =
             Connectivity.Agent.cmd(
               agent,
               Signals.new("connectivity.recheck", %{outage: 9, attempt: 1})
             )

    assert {:ok, checking, [_]} =
             Connectivity.Agent.cmd(
               agent,
               Signals.new("connectivity.recheck", %{outage: 10, attempt: 1})
             )

    assert checking.state.phase == :checking

    assert {:ok, ^checking, []} =
             Connectivity.Agent.cmd(
               checking,
               Signals.new("connectivity.recheck", %{outage: 10, attempt: 1})
             )

    completed = Signals.new("connectivity.recheck.completed", %{outage: 10, attempt: 1})
    assert {:ok, waiting, [_]} = Connectivity.Agent.cmd(checking, completed)
    assert {:ok, ^waiting, []} = Connectivity.Agent.cmd(waiting, completed)

    assert {:ok, restored, [_]} =
             Connectivity.Agent.cmd(
               waiting,
               Signals.new("connectivity.restored", %{revision: 11})
             )

    assert restored.state.outage == nil
    assert {:ok, ^restored, []} = Connectivity.Agent.cmd(restored, completed)
  end

  test "Alarmist derives expected Internet loss, not equipment-only or unconfigured status",
       ctx do
    Alarms.start(ctx.scope)
    Alarms.subscribe(ctx.scope)
    Alarms.update(ctx.scope, %{expected: false, online: false})
    eventually(fn -> match?({:clear, _}, Alarms.condition(ctx.scope)) end)
    Alarms.update(ctx.scope, %{expected: true, online: false})
    assert_receive %Alarmist.Event{state: :set}, 1_000
    eventually(fn -> match?({:set, _}, Alarms.condition(ctx.scope)) end)
    Alarms.update(ctx.scope, %{expected: true, online: true})
    eventually(fn -> match?({:clear, _}, Alarms.condition(ctx.scope)) end)
    Alarms.update(ctx.scope, :unavailable)
    eventually(fn -> match?({:set, _}, Alarms.condition(ctx.scope)) end)
  end

  test "native sensor routes loss, stops after three read-only rechecks and observes restoration",
       ctx do
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "connectivity:events")
    source = Signals.source(ctx.scope)
    agent = start_supervised!({Connectivity, ctx.opts})
    :ok = Jido.AgentServer.await_ready(agent)
    eventually(fn -> state(agent).phase == :exhausted end)
    assert Agent.get(@control, & &1.count) == 3
    assert state(agent).attempts == 3
    assert Network.status(@network).trial == nil
    assert {:ok, %{"network" => @wan}} = Config.load(ctx.path)
    assert_receive %Jido.Signal{type: "connectivity.lost", source: ^source}
    restore(ctx.host)
    eventually(fn -> state(agent).phase == :idle end)
    assert_receive %Jido.Signal{type: "connectivity.restored", source: ^source}
    assert Agent.get(@control, & &1.count) == 3
  end

  test "blocked rechecks are bounded, never overlap, and restore cancels the owned worker", ctx do
    Agent.update(@control, &%{&1 | hold: true})
    agent = start_supervised!({Connectivity, ctx.opts})
    assert_receive {:recheck, first}, 1_000
    first_ref = Process.monitor(first)
    assert_receive {:DOWN, ^first_ref, :process, ^first, _}, 1_000
    assert_receive {:recheck, second}, 1_000
    refute Process.alive?(first)
    second_ref = Process.monitor(second)
    restore(ctx.host)
    eventually(fn -> state(agent).phase == :idle end)
    assert_receive {:DOWN, ^second_ref, :process, ^second, _}, 1_000
    count = Agent.get(@control, & &1.count)
    Process.sleep(100)
    assert Agent.get(@control, & &1.count) == count
  end

  test "sensor restart reconciles an interrupted attempt without resetting its budget", ctx do
    Agent.update(@control, &%{&1 | hold: true})
    agent = start_supervised!({Connectivity, ctx.opts})
    assert_receive {:recheck, worker}, 1_000
    sensor = Jido.AgentServer.children(agent)[{:plugin, Plugin}].pid
    ref = Process.monitor(worker)
    Process.exit(sensor, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    eventually(fn -> state(agent).phase == :exhausted end)
    assert state(agent).attempts == 3
    assert Agent.get(@control, & &1.count) == 3
  end

  test "reconciliation replaces a lost native scheduler timer without resetting attempts", ctx do
    opts = Keyword.update!(ctx.opts, :monitoring, &Map.put(&1, :retry_ms, 120))
    agent = start_supervised!({Connectivity, opts})
    assert_receive {:recheck, _}, 1_000
    eventually(fn -> state(agent).phase == :waiting and state(agent).attempts == 1 end)
    scheduler = Jido.AgentServer.children(agent)[{:plugin, Jido.Plugin.Scheduler}].pid
    Process.exit(scheduler, :kill)

    eventually(fn ->
      pid = Jido.AgentServer.children(agent)[{:plugin, Jido.Plugin.Scheduler}].pid
      is_pid(pid) and pid != scheduler
    end)

    sensor = Jido.AgentServer.children(agent)[{:plugin, Plugin}].pid
    send(sensor, :reconcile)
    eventually(fn -> state(agent).phase == :exhausted end)
    assert Agent.get(@control, & &1.count) == 3
  end

  test "agent restart tears down workers and subscriptions, then reads current Alarmist condition",
       ctx do
    Agent.update(@control, &%{&1 | hold: true})
    agent = start_supervised!({Connectivity, Keyword.put(ctx.opts, :name, __MODULE__.Policy)})
    assert_receive {:recheck, worker}, 1_000
    sensor = Jido.AgentServer.children(agent)[{:plugin, Plugin}].pid
    ref = Process.monitor(worker)
    sensor_ref = Process.monitor(sensor)
    scheduler = Jido.AgentServer.children(agent)[{:plugin, Jido.Plugin.Scheduler}].pid
    scheduler_ref = Process.monitor(scheduler)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    assert_receive {:DOWN, ^sensor_ref, :process, ^sensor, _}, 1_000
    assert_receive {:DOWN, ^scheduler_ref, :process, ^scheduler, _}, 1_000
    eventually(fn -> Process.whereis(__MODULE__.Policy) not in [nil, agent] end)
    replacement = Process.whereis(__MODULE__.Policy)
    eventually(fn -> state(replacement).outage != nil end)
    registry = PropertyTable.Supervisor.registry_name(NervesGate.Properties)
    refute Enum.any?(Registry.lookup(registry, :subscriptions), fn {pid, _} -> pid == sensor end)
    assert Network.status(@network).trial == nil
  end

  defp restore(host) do
    ports = Host.snapshot(host).ports |> Enum.map(&%{&1 | connection: :internet})
    Host.simulate(%{ports: ports}, host)
  end

  defp state(agent), do: Jido.AgentServer.agent(agent).state

  defp eventually(fun, remaining \\ 150)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, remaining - 1)
        )
  end
end
