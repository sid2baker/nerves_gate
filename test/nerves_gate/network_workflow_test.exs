defmodule NervesGate.NetworkWorkflowTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Config, Network}
  alias NervesGate.Network.{Actions, Effect, Host, Plugin, Runtime, Signals, TrialStore}
  @moduletag :tmp_dir
  @network %{"mode" => "ports", "eth0" => nil, "eth1" => nil}
  @usb %{present: true, link: true, addresses: [%{address: "10.13.0.1", prefix_length: 30}]}
  @access %{local: "10.13.0.1", peer: {10, 13, 0, 2}}

  defmodule Controlled do
    @behaviour NervesGate.Network.Adapter
    def snapshot({host, _}), do: Host.snapshot(host)
    def observations({host, _}), do: Host.observations(host)

    def apply_config(network, {host, control}) do
      if network["mode"] == "ports" do
        %{hold: hold, owner: owner} = Agent.get(control, & &1)
        send(owner, {:applying, self()})
        if hold, do: receive(do: (:release -> :ok))
      end

      Host.apply_config(network, host)
    end
  end

  setup %{tmp_dir: dir} do
    host = start_supervised!({Host, name: nil})
    Host.simulate(%{usb: @usb}, host)
    owner = self()
    control = start_supervised!({Agent, fn -> %{hold: false, owner: owner} end})
    path = Path.join(dir, "config.json")

    server =
      start_supervised!(
        {Network,
         name: nil,
         path: path,
         adapter: {Controlled, {host, control}},
         poll_ms: 10,
         effect_ms: 2_000}
      )

    runtime = Network.runtime(server)
    agent = Network.agent(server)
    :ok = Jido.AgentServer.await_ready(agent)
    %{server: server, host: host, control: control, runtime: runtime, agent: agent, path: path}
  end

  test "pure workflow chooses manual confirmation, USB commit, wait and conflict rejection",
       ctx do
    {:ok, id} = Network.propose(@network, ctx.server)
    safety = Runtime.admission(ctx.runtime)
    signal = fact(safety)
    context = context(safety, signal)
    assert {:ok, %{phase: :awaiting_confirmation}} = Actions.Advance.run(signal.data, context)

    auto = put_in(safety.trial.auto_save, true)

    assert {:ok, %{phase: :confirming}, [%Effect{operation: :auto_confirm, id: ^id}]} =
             Actions.Advance.run(signal.data, context(auto, signal))

    waiting = %{auto | ready: false, observed: nil}
    waiting = put_in(waiting.workflow.proposal_reply_pending, true)

    assert {:ok, %{phase: :awaiting_readiness}, [%Effect{operation: :await}]} =
             Actions.Advance.run(signal.data, context(waiting, signal))

    waiting = put_in(waiting.workflow.proposal_reply_pending, false)

    assert {:ok, %{phase: :awaiting_readiness}} =
             Actions.Advance.run(signal.data, context(waiting, signal))

    collision = %{Host.snapshot(ctx.host) | usb: @usb}
    port = %{hd(collision.ports) | addresses: @usb.addresses}
    collision = %{collision | ports: [port]}
    conflicting = %{waiting | observed: collision}

    assert {:ok, %{phase: :rolling_back}, [%Effect{operation: :auto_cancel}]} =
             Actions.Advance.run(signal.data, context(conflicting, signal))
  end

  test "facts are incarnation-scoped, correlated and deduplicated; reconciliation can repeat",
       ctx do
    {:ok, id} = Network.propose(@network, ctx.server)
    safety = Runtime.admission(ctx.runtime)
    signal = fact(safety)
    context = context(safety, signal)
    assert {:ok, state} = Actions.Advance.run(signal.data, context)
    context = %{context | agent_state: state}
    assert {:ok, ^state} = Actions.Advance.run(signal.data, context)
    assert {:ok, ^state} = Actions.Advance.run(%{signal.data | sequence: 0}, context)
    assert {:ok, ^state} = Actions.Advance.run(%{signal.data | trial_id: "old"}, context)
    old = %{signal | source: Signals.source("old-runtime")}
    assert {:ok, ^state} = Actions.Advance.run(signal.data, %{context | signal: old})

    # Reconciliation is a request to re-read admission, not a replay of the fact.
    auto = put_in(safety.trial.auto_save, true)
    reconcile = fact(auto, "network.workflow.reconcile")
    context = %{context(auto, reconcile) | agent_state: state}

    assert {:ok, _, [%Effect{operation: :auto_confirm, id: ^id}]} =
             Actions.Advance.run(reconcile.data, context)

    assert {:ok, _, [%Effect{operation: :auto_confirm}]} =
             Actions.Advance.run(reconcile.data, context)

    # Runtime restart permits its lower sequence, never an older source's facts.
    fresh = put_in(safety.workflow.incarnation, "new-runtime")
    fresh = put_in(fresh.workflow.sequence, 1)
    fresh_signal = fact(fresh)

    assert {:ok, %{incarnation: "new-runtime", sequence: 1}} =
             Actions.Advance.run(fresh_signal.data, %{
               context(fresh, fresh_signal)
               | agent_state: state
             })
  end

  test "live execution state wins over a queued applied fact", ctx do
    {:ok, _} = Network.propose(@network, ctx.server)
    safety = Runtime.admission(ctx.runtime)
    signal = fact(safety)

    for phase <- [:applying, :confirming, :recovering] do
      busy = put_in(safety.workflow.phase, phase)
      assert {:ok, %{phase: ^phase}} = Actions.Advance.run(signal.data, context(busy, signal))
    end
  end

  test "runtime cannot auto-save a ready USB trial while the coordinating agent is suspended",
       ctx do
    Agent.update(ctx.control, &%{&1 | hold: true})
    caller = Task.async(fn -> Network.propose(@network, ctx.server, @access) end)
    assert_receive {:applying, worker}, 1_000
    :sys.suspend(ctx.agent)

    try do
      send(worker, :release)
      eventually(fn -> Runtime.admission(ctx.runtime).workflow.phase == :pending end)
      assert Network.status(ctx.server).ready
      assert {:ok, %{"phase" => "pending"}} = TrialStore.load(ctx.path)
      refute Network.status(ctx.server).config["setup_completed"]
      assert Task.yield(caller, 30) == nil
    after
      :sys.resume(ctx.agent)
    end

    assert {:ok, _} = Task.await(caller)
    assert Network.status(ctx.server).trial == nil
    assert {:ok, %{"setup_completed" => true, "network" => @network}} = Config.load(ctx.path)
  end

  test "manual trials are never auto-saved and automatic effects cannot bypass confirmation",
       ctx do
    {:ok, id} = Network.propose(@network, ctx.server)

    for operation <- [:auto_confirm, :auto_cancel, :await] do
      assert {:error, :confirmation_required} =
               Runtime.execute(ctx.runtime, %Effect{operation: operation, id: id}, %{})
    end

    assert Network.status(ctx.server).trial.id == id
    refute Network.status(ctx.server).config["setup_completed"]
    assert :ok = Network.cancel(id, ctx.server)
  end

  test "stale automatic decisions are vetoed without substituting another operation", ctx do
    unready = %{usb: @usb, ports: Host.snapshot(ctx.host).ports}
    Host.simulate(unready, ctx.host)
    {:ok, id} = Network.propose(@network, ctx.server, @access)
    :sys.suspend(ctx.agent)

    try do
      assert {:error, :not_connected} =
               Runtime.execute(ctx.runtime, %Effect{operation: :auto_confirm, id: id}, %{})

      assert {:error, :stale_decision} =
               Runtime.execute(ctx.runtime, %Effect{operation: :auto_cancel, id: id}, %{})

      Host.simulate(%{usb: @usb}, ctx.host)

      assert {:error, :stale_decision} =
               Runtime.execute(ctx.runtime, %Effect{operation: :await, id: id}, %{})

      assert {:error, :no_matching_trial} =
               Runtime.execute(ctx.runtime, %Effect{operation: :auto_confirm, id: "old"}, %{})

      safety = Runtime.admission(ctx.runtime)
      signal = fact(safety)
      assert {:ok, _, [commit]} = Actions.Advance.run(signal.data, context(safety, signal))
      assert commit.operation == :auto_confirm
      Host.simulate(unready, ctx.host)
      assert {:error, :not_connected} = Runtime.execute(ctx.runtime, commit, %{})
      assert {:ok, %{"phase" => "pending"}} = TrialStore.load(ctx.path)
      Host.simulate(%{usb: @usb}, ctx.host)
    after
      :sys.resume(ctx.agent)
    end

    eventually(fn -> Network.status(ctx.server).trial == nil end)
  end

  test "lost readiness notification is repaired without a new property event or revision", ctx do
    Host.simulate(%{usb: @usb, ports: Host.snapshot(ctx.host).ports}, ctx.host)
    {:ok, id} = Network.propose(@network, ctx.server, @access)
    original = :sys.get_state(ctx.runtime)
    revision = Network.status(ctx.server).revision
    # Suppress the outgoing agent lookup only; the runtime's registry name,
    # owner monitor and durable trial remain intact. This drops the first hint.
    :sys.replace_state(ctx.runtime, &%{&1 | id: "unroutable-test-instance"})

    # Drain facts already queued before routing was suppressed.
    barrier = Jido.Signal.new!("network.validate", %{network: @network}, source: "/test")
    assert {:ok, _} = Jido.AgentServer.call(ctx.agent, barrier)

    try do
      Host.simulate(%{usb: @usb}, ctx.host)
      eventually(fn -> :sys.get_state(ctx.runtime).workflow_hint == {id, true, false, false} end)
      assert Network.status(ctx.server).revision == revision
      assert {:ok, %{"phase" => "pending"}} = TrialStore.load(ctx.path)
    after
      :sys.replace_state(ctx.runtime, &%{&1 | id: original.id})
    end

    # No more properties change. The one-second reconciliation repairs delivery.
    eventually(fn -> Network.status(ctx.server).trial == nil end, 200)
    assert Network.status(ctx.server).config["setup_completed"]
  end

  test "independent watchdog rolls back even after apply while the agent is suspended", ctx do
    Agent.update(ctx.control, &%{&1 | hold: true})
    caller = Task.async(fn -> Network.propose(@network, ctx.server, @access) end)
    assert_receive {:applying, worker}, 1_000
    :sys.suspend(ctx.agent)

    try do
      send(worker, :release)
      eventually(fn -> Runtime.admission(ctx.runtime).workflow.phase == :pending end)
      :sys.replace_state(ctx.runtime, &%{&1 | deadline: System.monotonic_time(:millisecond) - 1})
      send(ctx.runtime, :poll)

      eventually(fn ->
        status = Network.status(ctx.server)
        status.trial == nil and not status.recovering
      end)

      refute Network.status(ctx.server).config["setup_completed"]
      assert {:ok, nil} = TrialStore.load(ctx.path)
    after
      :sys.resume(ctx.agent)
    end

    assert {:error, :expired} = Task.await(caller)
  end

  defp fact(safety, type \\ "network.configuration.applied") do
    workflow = safety.workflow
    Signals.new(type, workflow.trial_id, workflow.phase, workflow.sequence, workflow.incarnation)
  end

  defp context(safety, signal) do
    %{
      agent_state: Network.Agent.new!().state,
      signal: signal,
      plugin_inputs: %{Plugin => %Jido.Plugin.Input{runtime: safety}}
    }
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
