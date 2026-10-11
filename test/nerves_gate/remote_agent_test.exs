defmodule NervesGate.RemoteAgentTest do
  use ExUnit.Case, async: true
  alias NervesGate.Remote
  alias NervesGate.Remote.{Actions, Effect, Plugin, Signals}

  defmodule Controlled do
    @behaviour Remote.Adapter
    def snapshot(control), do: Agent.get(control, & &1.snapshot)
    def login_url(control), do: Agent.get(control, & &1.url)

    def execute(operation, params, control) do
      owner = Agent.get(control, & &1.owner)
      send(owner, {:executing, self(), operation, params})

      receive do
        {:finish, result} -> result
        :crash -> exit(:injected_failure)
      end
    end
  end

  setup do
    owner = self()

    control =
      start_supervised!(
        {Agent, fn -> %{snapshot: Remote.Host.defaults(), url: nil, owner: owner} end}
      )

    remote =
      start_supervised!(
        {Remote, name: nil, adapter: {Controlled, control}, poll_ms: 10, timeout: 2_000}
      )

    %{remote: remote, control: control}
  end

  test "pure commands validate input, emit typed effects and reject conflicts", ctx do
    context = %{
      agent_state: Remote.Agent.new!().state,
      plugin_inputs: %{Plugin => %Jido.Plugin.Input{runtime: Remote.status(ctx.remote)}}
    }

    assert {:ok, %{phase: :running, operation_id: "one", outcome: :pending},
            [%Effect{operation: :connect, id: "one", params: %{hostname: "gateway"}}]} =
             Actions.Connect.run(%{params: %{"hostname" => "Gateway"}, id: "one"}, context)

    for params <- [%{}, %{"hostname" => "bad name"}, %{"hostname" => <<255>>}] do
      assert {:ok, %{outcome: {:error, %{code: "invalid_parameters"}}}} =
               Actions.Configure.run(%{params: params, id: "two"}, context)
    end

    context = put_in(context.plugin_inputs[Plugin].runtime.operation, "connect")

    assert {:ok, %{outcome: {:error, %{code: "remote_busy"}}}} =
             Actions.Disconnect.run(%{params: %{}, id: "three"}, context)

    refute_receive {:executing, _, _, _}
  end

  test "malformed native input does not poison subsequent commands", ctx do
    agent = Remote.agent(ctx.remote)
    :ok = Jido.AgentServer.await_ready(agent)
    bad = Jido.Signal.new!(%{type: "remote.configure", source: "/test", data: %{id: 42}})

    assert {:error, %Jido.Action.Error.InvalidInputError{}} = Jido.AgentServer.call(agent, bad)
    assert :ok = Remote.command(:configure, %{"hostname" => "valid"}, ctx.remote)
    assert_receive {:executing, worker, :configure, %{hostname: "valid"}}
    send(worker, {:finish, :ok})
    eventually(fn -> Remote.status(ctx.remote).operation == nil end)
  end

  test "duplicate, stale and unrelated completion facts cannot finish another operation" do
    started = Signals.new("remote.operation.started", "first", :running, 2)
    assert {:ok, agent, []} = Remote.Agent.cmd(Remote.Agent.new!(), started)
    assert {:ok, ^agent, []} = Remote.Agent.cmd(agent, started)

    for signal <- [
          Signals.new("remote.operation.completed", "first", :idle, 1),
          Signals.new("remote.operation.failed", "other", :idle, 3)
        ] do
      assert {:ok, ^agent, []} = Remote.Agent.cmd(agent, signal)
    end

    assert {:ok, next, []} =
             Remote.Agent.cmd(agent, Signals.new("remote.operation.completed", "first", :idle, 3))

    assert next.state.phase == :idle
    assert next.state.operation_id == nil
  end

  test "agent crash stops its worker without replaying the daemon mutation", ctx do
    assert :ok = Remote.command(:connect, %{"hostname" => "gateway"}, ctx.remote)
    assert_receive {:executing, worker, :connect, _}
    monitor = Process.monitor(worker)
    agent = Remote.agent(ctx.remote)
    runtime = Remote.runtime(ctx.remote)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    eventually(fn -> Remote.agent(ctx.remote) not in [nil, agent] end)
    assert Remote.runtime(ctx.remote) == runtime
    assert Remote.status(ctx.remote).operation == nil
    assert Remote.status(ctx.remote).error.code == "remote_outcome_unknown"
    refute_receive {:executing, _, _, _}, 50
    assert :ok = Remote.command(:configure, %{"hostname" => "explicit-retry"}, ctx.remote)
  end

  test "runtime restart kills the worker, restarts the agent and only observes", ctx do
    assert :ok = Remote.command(:configure, %{"hostname" => "new-name"}, ctx.remote)
    assert_receive {:executing, worker, :configure, _}
    monitor = Process.monitor(worker)
    runtime = Remote.runtime(ctx.remote)
    agent = Remote.agent(ctx.remote)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    eventually(fn -> Remote.runtime(ctx.remote) not in [nil, runtime] end)
    eventually(fn -> Remote.agent(ctx.remote) not in [nil, agent] end)
    assert Remote.status(ctx.remote).hostname == "nerves-gate"
    assert Remote.status(ctx.remote).operation == nil
    refute_receive {:executing, _, _, _}, 50
  end

  test "concurrent enrollment requests admit at most one daemon worker", ctx do
    results =
      1..6
      |> Enum.map(fn _ ->
        Task.async(fn -> Remote.command(:connect, %{"hostname" => "gateway"}, ctx.remote) end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &match?({:error, %{code: "remote_busy"}}, &1)) == 5
    assert_receive {:executing, worker, :connect, _}
    refute_receive {:executing, _, _, _}, 20
    send(worker, {:finish, :ok})
  end

  test "private query and daemon URL result never enter agent state or public facts", ctx do
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "remote:events")
    source = Signals.source(:sys.get_state(Remote.runtime(ctx.remote)).incarnation)
    url = "https://login.tailscale.com/a/private-agent-token"
    Agent.update(ctx.control, &%{&1 | url: url})
    assert Remote.login_url(ctx.remote) == url
    assert :ok = Remote.command(:connect, %{"hostname" => "gateway"}, ctx.remote)
    assert_receive {:executing, worker, :connect, _}
    send(worker, {:finish, {:ok, url}})
    eventually(fn -> Remote.status(ctx.remote).operation == nil end)
    agent = Jido.AgentServer.agent(Remote.agent(ctx.remote))
    refute inspect(agent.state) =~ "private-agent-token"
    refute inspect(Remote.status(ctx.remote)) =~ "private-agent-token"
    assert_receive %Jido.Signal{type: "remote.operation.completed", source: ^source} = event
    refute inspect(event) =~ "private-agent-token"
    assert Map.keys(event.data) |> Enum.sort() == [:operation_id, :phase, :sequence]
  end

  test "significant connection observations become facts, unchanged polls do not", ctx do
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "remote:events")
    source = Signals.source(:sys.get_state(Remote.runtime(ctx.remote)).incarnation)
    Agent.update(ctx.control, &put_in(&1.snapshot.state, "online"))
    assert Remote.status(ctx.remote).state == "online"
    assert_receive %Jido.Signal{type: "remote.connection.established", source: ^source}
    refute_receive %Jido.Signal{type: "remote.connection.established", source: ^source}, 40
    Agent.update(ctx.control, &put_in(&1.snapshot.state, "offline"))
    assert_receive %Jido.Signal{type: "remote.connection.lost", source: ^source}, 200
  end

  test "adapter exit is sanitized and emits a correlated enrollment failure", ctx do
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "remote:events")
    source = Signals.source(:sys.get_state(Remote.runtime(ctx.remote)).incarnation)
    assert :ok = Remote.command(:connect, %{"hostname" => "gateway"}, ctx.remote)
    assert_receive {:executing, worker, :connect, _}

    assert_receive %Jido.Signal{
      type: "remote.connection.requested",
      source: ^source,
      data: %{operation_id: id}
    }

    send(worker, :crash)

    assert_receive %Jido.Signal{
                     type: "remote.enrollment.failed",
                     source: ^source,
                     data: %{operation_id: ^id, phase: :idle}
                   },
                   1_000

    assert Remote.status(ctx.remote).error.code == "remote_failed"
    refute inspect(Remote.status(ctx.remote)) =~ "injected_failure"
  end

  defp eventually(fun, attempts \\ 100)
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
