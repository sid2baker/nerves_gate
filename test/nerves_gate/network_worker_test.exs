defmodule NervesGate.NetworkWorkerTest do
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

    start_supervised!(
      {Network,
       name: __MODULE__, adapter: {Adapter, adapter}, trial_ms: 1_000, poll_ms: 10, effect_ms: 300}
    )

    on_exit(fn -> NervesGate.Alarms.report(:network_restore_failed, __MODULE__, false) end)
    %{server: __MODULE__, host: host, adapter: adapter}
  end

  test "validation is pure and commands use one domain worker", ctx do
    before = Adapter.calls(ctx.adapter)
    assert {:ok, @network} = Network.validate(@network)
    assert {:error, _} = Network.validate(%{"mode" => "wifi"})
    assert Adapter.calls(ctx.adapter) == before
    assert Map.get(Network.child_spec([]), :type, :worker) == :worker
    assert {:ok, id} = Network.propose(@network, ctx.server)
    assert :ok = Network.cancel(id, ctx.server)
  end

  test "a transient observation failure clears on recovery without hardware writes", ctx do
    before = Adapter.calls(ctx.adapter)
    Adapter.fail(ctx.adapter, :snapshot, :unavailable)
    assert %{observed: nil, error: {:discovery, :unavailable}} = Network.status(ctx.server)
    Adapter.fail(ctx.adapter, :snapshot, nil)
    assert Network.status(ctx.server).observed != nil
    assert Network.status(ctx.server).error == nil
    assert Adapter.calls(ctx.adapter) == before
  end

  test "deferred replies leave the server responsive and serialize admission", ctx do
    {caller, worker, _} = blocked_proposal(ctx)
    assert Network.status(ctx.server).phase == :apply
    assert {:error, :trial_in_progress} = Network.propose(@network, ctx.server)
    send(worker, :continue)
    assert {:ok, id} = Task.await(caller)
    assert :ok = Network.cancel(id, ctx.server)
  end

  test "server restart restores saved subsystem settings before accepting commands", ctx do
    {:ok, _} = Network.propose(@network, ctx.server)
    old = Process.whereis(ctx.server)
    Process.exit(old, :kill)
    eventually(fn -> Process.whereis(ctx.server) not in [nil, old] and restored?(ctx) end)
    assert Host.load(ctx.host) == {:ok, Config.defaults()}
    assert {:ok, id} = Network.propose(@network, ctx.server)
    assert :ok = Network.cancel(id, ctx.server)
  end

  test "watchdog joins a blocked apply before restoring; no orphan can apply later", ctx do
    {caller, worker, ref} = blocked_proposal(ctx)
    assert Network.status(ctx.server).trial != nil
    assert {:error, :operation_timeout} = Task.await(caller)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    send(worker, :continue)
    assert restored?(ctx)
  end

  test "server death kills its in-flight hardware worker", ctx do
    Adapter.hold(ctx.adapter, :apply, @network)
    caller = Task.async(fn -> NervesGate.network_propose(@network, network: ctx.server) end)
    assert_receive {:blocked, :apply, worker}, 1_000
    ref = Process.monitor(worker)
    old = Process.whereis(ctx.server)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    assert {:error, %{code: "outcome_unknown"}} = Task.await(caller)
    eventually(fn -> Process.whereis(ctx.server) not in [nil, old] and restored?(ctx) end)
  end

  test "trial deadline interrupts blocked apply independently of the worker timeout", ctx do
    :sys.replace_state(ctx.server, &%{&1 | effect_ms: 5_000})
    {caller, worker, ref} = blocked_proposal(ctx)

    :sys.replace_state(ctx.server, fn state ->
      Process.cancel_timer(state.timer)
      timer = Process.send_after(self(), {:expire, state.trial.id}, 25)
      %{state | timer: timer, deadline: System.monotonic_time(:millisecond) + 25}
    end)

    assert {:error, :expired} = Task.await(caller)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert restored?(ctx)
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
    server = Process.whereis(ctx.server)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:apply, {:worker_failed, {%RuntimeError{}, _}}}} =
                 Network.propose(@network, ctx.server)
      end)

    assert log =~ "injected apply failure"
    assert Process.whereis(ctx.server) == server
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
    assert {:timeout, _} = catch_exit(GenServer.call(ctx.server, {:propose, @network, nil}, 20))
    assert_receive {:blocked, :apply, worker}
    assert Process.alive?(worker)
    send(worker, :continue)
    eventually(fn -> Network.status(ctx.server).phase == :pending end)
    refute_receive {_ref, _result}, 30
    assert :ok = Network.cancel(Network.status(ctx.server).trial.id, ctx.server)
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
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
