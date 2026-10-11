defmodule NervesGate.NetworkAgentTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Config, Network}
  alias NervesGate.Network.Host
  alias NervesGate.TestNetworkAdapter, as: Adapter

  @network %{
    "mode" => "shared",
    "equipment" => %{
      "ip_method" => "static",
      "static_ip" => "192.168.20.2",
      "subnet_mask" => "255.255.255.0",
      "gateway" => nil
    }
  }

  setup do
    host = start_supervised!({Host, name: nil})
    adapter = start_supervised!({Adapter, host: host, owner: self()})

    server =
      start_supervised!(
        {Network,
         name: nil, adapter: {Adapter, adapter}, trial_ms: 1_000, poll_ms: 10, effect_ms: 300}
      )

    %{server: server, host: host, adapter: adapter}
  end

  test "validation is pure and Jido evaluates reconciliation independently of commands", ctx do
    before = Adapter.calls(ctx.adapter)
    assert {:ok, @network} = Network.validate(@network)
    assert {:error, _} = Network.validate(%{"mode" => "wifi"})
    assert Adapter.calls(ctx.adapter) == before
    agent = Network.agent(ctx.server)
    :ok = Jido.AgentServer.await_ready(agent)
    signal = Jido.Signal.new!("network.reconcile", %{}, source: "/test")
    assert {:ok, _} = Jido.AgentServer.call(agent, signal)
    assert {:ok, id} = Network.propose(@network, ctx.server)
    assert :ok = Network.cancel(id, ctx.server)
  end

  test "deferred replies leave the runtime responsive and serialize admission", ctx do
    {caller, worker, _} = blocked_proposal(ctx)
    assert Network.status(ctx.server).phase == :apply
    assert {:error, :trial_in_progress} = Network.propose(@network, ctx.server)
    send(worker, :continue)
    assert {:ok, id} = Task.await(caller)
    assert :ok = Network.cancel(id, ctx.server)
  end

  test "agent crash rolls back without restarting the safety runtime", ctx do
    {:ok, _} = Network.propose(@network, ctx.server)
    runtime = Network.runtime(ctx.server)
    agent = Network.agent(ctx.server)
    Process.exit(agent, :kill)
    eventually(fn -> Network.agent(ctx.server) not in [nil, agent] and restored?(ctx) end)
    assert Network.runtime(ctx.server) == runtime
    assert Host.load(ctx.host) == {:ok, Config.defaults()}
    assert {:ok, _} = Network.propose(@network, ctx.server)
  end

  test "runtime crash restores subsystem settings and restarts its dependent agent", ctx do
    {:ok, _} = Network.propose(@network, ctx.server)
    runtime = Network.runtime(ctx.server)
    agent = Network.agent(ctx.server)
    Process.exit(runtime, :kill)
    eventually(fn -> Network.runtime(ctx.server) not in [nil, runtime] end)
    eventually(fn -> Network.agent(ctx.server) not in [nil, agent] and restored?(ctx) end)
  end

  test "watchdog joins a blocked apply before restoring; no orphan can apply later", ctx do
    {caller, worker, ref} = blocked_proposal(ctx)
    assert Network.status(ctx.server).trial != nil
    assert {:error, :operation_timeout} = Task.await(caller)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    send(worker, :continue)
    assert restored?(ctx)
  end

  test "runtime death kills its in-flight hardware worker", ctx do
    Adapter.hold(ctx.adapter, :apply, @network)
    caller = Task.async(fn -> NervesGate.network_propose(@network, network: ctx.server) end)
    assert_receive {:blocked, :apply, worker}, 1_000
    ref = Process.monitor(worker)
    runtime = Network.runtime(ctx.server)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    assert {:error, %{code: "outcome_unknown"}} = Task.await(caller)
    eventually(fn -> Network.runtime(ctx.server) not in [nil, runtime] and restored?(ctx) end)
  end

  test "trial deadline interrupts blocked apply even with its agent suspended", ctx do
    runtime = Network.runtime(ctx.server)
    :sys.replace_state(runtime, &%{&1 | effect_ms: 5_000})
    {caller, worker, ref} = blocked_proposal(ctx)
    agent = Network.agent(ctx.server)
    :sys.suspend(agent)

    try do
      :sys.replace_state(runtime, fn state ->
        Process.cancel_timer(state.timer)
        timer = Process.send_after(self(), {:expire, state.trial.id}, 25)
        %{state | timer: timer, deadline: System.monotonic_time(:millisecond) + 25}
      end)

      assert {:error, :expired} = Task.await(caller)
      assert_receive {:DOWN, ^ref, :process, ^worker, _}
      assert restored?(ctx)
    after
      :sys.resume(agent)
    end
  end

  test "agent failure during an effect cannot leave its hardware worker alive", ctx do
    {caller, worker, ref} = blocked_proposal(ctx)
    Process.exit(Network.agent(ctx.server), :kill)
    assert {:error, :agent_restarted} = Task.await(caller)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    eventually(fn -> restored?(ctx) end)
  end

  test "bounded save failure restores only after joining the save worker", ctx do
    {:ok, id} = Network.propose(@network, ctx.server)
    Adapter.hold(ctx.adapter, :save, @network)
    caller = Task.async(fn -> Network.confirm(id, ctx.server) end)
    assert_receive {:blocked, :save, worker}, 1_000
    ref = Process.monitor(worker)
    assert {:error, :operation_timeout} = Task.await(caller)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert restored?(ctx)
    assert Host.load(ctx.host) == {:ok, Config.defaults()}
  end

  test "proposal rejection is acknowledged after restoration completes", ctx do
    Adapter.fail(ctx.adapter, :apply, :offline)
    Adapter.hold(ctx.adapter, :apply, Config.defaults()["network"])
    caller = Task.async(fn -> Network.propose(@network, ctx.server) end)
    assert_receive {:blocked, :apply, worker}, 1_000
    assert Task.yield(caller, 20) == nil
    send(worker, :continue)
    assert {:error, {:apply, :offline}} = Task.await(caller)
    assert Network.status(ctx.server).recovering
    Adapter.fail(ctx.adapter, :apply, nil)
    Adapter.hold(ctx.adapter, :apply, :never)
    eventually(fn -> restored?(ctx) end)
  end

  test "worker exceptions are logged and DOWN triggers restoration", ctx do
    Adapter.crash(ctx.adapter, :apply, @network)
    runtime = Network.runtime(ctx.server)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:apply, {:worker_failed, {%RuntimeError{}, _}}}} =
                 Network.propose(@network, ctx.server)
      end)

    assert log =~ "injected apply failure"
    assert Network.runtime(ctx.server) == runtime
    assert restored?(ctx)
  end

  @tag :capture_log
  test "a startup task crash is not misreported as a timeout", ctx do
    Adapter.crash(ctx.adapter, :load, nil)

    server =
      start_supervised!(
        Supervisor.child_spec(
          {Network, name: nil, adapter: {Adapter, ctx.adapter}},
          id: :load_crash
        )
      )

    assert %{config: nil, error: {:load, {:worker_failed, {%RuntimeError{}, _}}}} =
             Network.status(server)
  end

  test "a caller timeout leaves the trial protected and OTP drops the late reply", ctx do
    Adapter.hold(ctx.adapter, :apply, @network)
    runtime = Network.runtime(ctx.server)
    assert {:timeout, _} = catch_exit(GenServer.call(runtime, {:propose, @network, nil}, 20))
    assert_receive {:blocked, :apply, worker}
    assert Process.alive?(worker)
    send(worker, :continue)
    eventually(fn -> Network.status(ctx.server).phase == :pending end)
    refute_receive {_ref, _result}, 30
    assert :ok = Network.cancel(Network.status(ctx.server).trial.id, ctx.server)
  end

  test "manual commands do not wait for a Jido turn", ctx do
    agent = Network.agent(ctx.server)
    :sys.suspend(agent)

    try do
      assert {:ok, id} = Network.propose(@network, ctx.server)
      assert :ok = Network.cancel(id, ctx.server)
    after
      :sys.resume(agent)
    end
  end

  defp blocked_proposal(ctx) do
    Adapter.hold(ctx.adapter, :apply, @network)
    caller = Task.async(fn -> Network.propose(@network, ctx.server) end)
    assert_receive {:blocked, :apply, worker}, 1_000
    {caller, worker, Process.monitor(worker)}
  end

  defp restored?(ctx) do
    status = Network.status(ctx.server)

    status.trial == nil and not status.recovering and
      Host.snapshot(ctx.host).bridge.method == "disabled"
  catch
    :exit, _ -> false
  end

  defp eventually(fun, attempts \\ 150)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
