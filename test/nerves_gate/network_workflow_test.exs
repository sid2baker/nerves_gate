defmodule NervesGate.NetworkWorkflowTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Config, Network}
  alias NervesGate.Network.{Actions, Effect, Host, Plugin, Runtime}
  alias NervesGate.TestNetworkAdapter, as: Adapter
  @network %{"mode" => "ports", "eth0" => nil, "eth1" => nil}
  @usb %{present: true, link: true, addresses: [%{address: "10.13.0.1", prefix_length: 30}]}
  @access %{local: "10.13.0.1", peer: {10, 13, 0, 2}}

  setup do
    host = start_supervised!({Host, name: nil})
    Host.simulate(%{usb: @usb}, host)
    adapter = start_supervised!({Adapter, host: host, owner: self()})

    server =
      start_supervised!(
        {Network, name: nil, adapter: {Adapter, adapter}, poll_ms: 10, effect_ms: 2_000}
      )

    agent = Network.agent(server)
    :ok = Jido.AgentServer.await_ready(agent)

    %{
      server: server,
      host: host,
      adapter: adapter,
      runtime: Network.runtime(server),
      agent: agent
    }
  end

  test "pure policy chooses USB save, wait and conflict rejection; manual trials stay manual",
       ctx do
    {:ok, id} = Network.propose(@network, ctx.server)
    safety = Runtime.admission(ctx.runtime)
    assert {:ok, _} = advance(safety)
    auto = put_in(safety.trial.auto_save, true)
    assert {:ok, _, [%Effect{operation: :auto_confirm, id: ^id}]} = advance(auto)
    waiting = %{auto | ready: false, observed: nil, proposal_reply_pending: true}
    assert {:ok, _, [%Effect{operation: :await}]} = advance(waiting)
    waiting = %{waiting | proposal_reply_pending: false}
    assert {:ok, _} = advance(waiting)
    collision = Host.snapshot(ctx.host)
    port = %{hd(collision.ports) | addresses: @usb.addresses}

    assert {:ok, _, [%Effect{operation: :auto_cancel}]} =
             advance(%{waiting | observed: %{collision | ports: [port]}})

    for phase <- [:apply, :save, :restore, :idle] do
      assert {:ok, _} = advance(%{auto | phase: phase})
    end
  end

  test "hints carry no authority; duplicate or stale data always uses live admission", ctx do
    {:ok, id} = Network.propose(@network, ctx.server)
    safety = Runtime.admission(ctx.runtime) |> put_in([:trial, :auto_save], true)
    signal = Jido.Signal.new!("network.reconcile", %{}, source: "/test")

    assert {:ok, %{executable: Actions.Advance}} =
             Jido.Agent.handle_signal(signal, Network.Agent.new!())

    context = context(safety)

    for data <- [%{}, %{trial_id: "old", phase: :save}, %{sequence: 1}] do
      assert {:ok, _, [%Effect{operation: :auto_confirm, id: ^id}]} =
               Actions.Advance.run(data, context)
    end

    assert :ok = Network.cancel(id, ctx.server)
    assert {:ok, _} = advance(Runtime.admission(ctx.runtime))

    assert {:error, :no_matching_trial} =
             Runtime.execute(ctx.runtime, %NervesGate.Network.Effect{
               operation: :auto_confirm,
               id: id
             })
  end

  test "only Jido can decide auto-save; runtime stays temporary while agent is suspended", ctx do
    {caller, worker} = suspend_during_apply(ctx)

    try do
      send(worker, :continue)
      eventually(fn -> Runtime.admission(ctx.runtime).phase == :pending end)
      assert Network.status(ctx.server).ready
      assert Host.load(ctx.host) == {:ok, Config.defaults()}
      assert Task.yield(caller, 30) == nil
    after
      :sys.resume(ctx.agent)
    end

    assert {:ok, _} = Task.await(caller)
    assert Network.status(ctx.server).trial == nil
    assert Host.load(ctx.host) == {:ok, Config.from_network(@network)}
  end

  test "automatic effects cannot bypass manual confirmation", ctx do
    {:ok, id} = Network.propose(@network, ctx.server)

    for operation <- [:auto_confirm, :auto_cancel, :await] do
      assert {:error, :confirmation_required} =
               Runtime.execute(ctx.runtime, %NervesGate.Network.Effect{
                 operation: operation,
                 id: id
               })
    end

    assert Network.status(ctx.server).trial.id == id
    assert :ok = Network.cancel(id, ctx.server)
  end

  test "runtime vetoes stale auto decisions without substituting another operation", ctx do
    unready = %{usb: @usb, ports: Host.snapshot(ctx.host).ports}
    Host.simulate(unready, ctx.host)
    {:ok, id} = Network.propose(@network, ctx.server, @access)
    :sys.suspend(ctx.agent)

    try do
      for operation <- [:auto_confirm, :auto_cancel] do
        assert {:error, :stale_decision} =
                 Runtime.execute(ctx.runtime, %NervesGate.Network.Effect{
                   operation: operation,
                   id: id
                 })
      end

      Host.simulate(%{usb: @usb}, ctx.host)

      assert {:error, :stale_decision} =
               Runtime.execute(ctx.runtime, %NervesGate.Network.Effect{
                 operation: :await,
                 id: id
               })

      assert {:error, :no_matching_trial} =
               Runtime.execute(ctx.runtime, %NervesGate.Network.Effect{
                 operation: :auto_confirm,
                 id: "old"
               })

      assert {:ok, _, [save]} = advance(Runtime.admission(ctx.runtime))
      Host.simulate(unready, ctx.host)
      assert {:error, :stale_decision} = Runtime.execute(ctx.runtime, save)
      assert Host.load(ctx.host) == {:ok, Config.defaults()}
      Host.simulate(%{usb: @usb}, ctx.host)
    after
      :sys.resume(ctx.agent)
    end

    eventually(fn -> Network.status(ctx.server).trial == nil end)
  end

  test "polling repairs a dropped readiness hint without a new observation", ctx do
    Host.simulate(%{usb: @usb, ports: Host.snapshot(ctx.host).ports}, ctx.host)
    {:ok, _} = Network.propose(@network, ctx.server, @access)
    original = :sys.get_state(ctx.runtime)
    :sys.replace_state(ctx.runtime, &%{&1 | id: "unroutable-test-instance"})
    # Drain earlier hints while readiness is still false; new hints cannot route.
    barrier = Jido.Signal.new!("network.reconcile", %{}, source: "/test")
    assert {:ok, _} = Jido.AgentServer.call(ctx.agent, barrier)

    try do
      Host.simulate(%{usb: @usb}, ctx.host)
      eventually(fn -> Runtime.admission(ctx.runtime).ready end)
      assert Host.load(ctx.host) == {:ok, Config.defaults()}
    after
      :sys.replace_state(ctx.runtime, &%{&1 | id: original.id})
    end

    eventually(fn -> Network.status(ctx.server).trial == nil end)
    assert Network.status(ctx.server).config["setup_completed"]
  end

  test "independent watchdog restores applied USB trial even with agent suspended", ctx do
    {caller, worker} = suspend_during_apply(ctx)

    try do
      send(worker, :continue)
      eventually(fn -> Runtime.admission(ctx.runtime).phase == :pending end)
      :sys.replace_state(ctx.runtime, &%{&1 | deadline: System.monotonic_time(:millisecond) - 1})
      send(ctx.runtime, :poll)

      eventually(fn ->
        status = Network.status(ctx.server)
        status.trial == nil and not status.recovering
      end)

      assert Host.load(ctx.host) == {:ok, Config.defaults()}
    after
      :sys.resume(ctx.agent)
    end

    assert {:error, :expired} = Task.await(caller)
  end

  defp suspend_during_apply(ctx) do
    Adapter.hold(ctx.adapter, :apply, @network)
    caller = Task.async(fn -> Network.propose(@network, ctx.server, @access) end)
    assert_receive {:blocked, :apply, worker}, 1_000
    :sys.suspend(ctx.agent)
    {caller, worker}
  end

  defp advance(safety), do: Actions.Advance.run(%{}, context(safety))

  defp context(safety),
    do: %{
      agent_state: Network.Agent.new!().state,
      plugin_inputs: %{Plugin => %Jido.Plugin.Input{runtime: safety}}
    }

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
