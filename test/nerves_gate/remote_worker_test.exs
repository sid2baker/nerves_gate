defmodule NervesGate.RemoteWorkerTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Observations, Remote}

  defmodule Controlled do
    @behaviour Remote.Adapter
    def snapshot(control), do: Agent.get(control, & &1.snapshot)
    def login_url(control), do: Agent.get(control, & &1.url)

    def execute(operation, params, control) do
      send(Agent.get(control, & &1.owner), {:executing, self(), operation, params})

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

    name = {:global, {__MODULE__, make_ref()}}

    remote =
      start_supervised!(
        {Remote, name: name, adapter: {Controlled, control}, poll_ms: 10, timeout: 2_000}
      )

    Remote.observe(name)
    %{remote: remote, name: name, control: control}
  end

  test "default server has a stable observation address" do
    assert {Observations.table(), Observations.workflow("remote", inspect(Remote))} in GenServer.call(
             Remote,
             :observations
           )
  end

  test "restart kills the worker and observes without replaying a mutation", ctx do
    sources = GenServer.call(ctx.name, :observations)
    assert :ok = Remote.command(:connect, %{"hostname" => "gateway"}, ctx.name)
    assert_receive {:executing, worker, :connect, _}
    monitor = Process.monitor(worker)
    Process.exit(ctx.remote, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    eventually(fn -> GenServer.whereis(ctx.name) not in [nil, ctx.remote] end)
    assert Remote.status(ctx.name).hostname == "nerves-gate"
    assert Remote.status(ctx.name).operation == nil
    assert GenServer.call(ctx.name, :observations) == sources
    refute_receive {:executing, _, _, _}, 50
    assert :ok = Remote.command(:configure, %{"hostname" => "explicit-retry"}, ctx.name)
  end

  test "concurrent enrollment requests admit at most one daemon worker", ctx do
    results =
      1..6
      |> Enum.map(fn _ ->
        Task.async(fn -> Remote.command(:connect, %{"hostname" => "gateway"}, ctx.name) end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &match?({:error, %{code: "remote_busy"}}, &1)) == 5
    assert_receive {:executing, worker, :connect, _}
    refute_receive {:executing, _, _, _}, 20
    send(worker, {:finish, :ok})
  end

  test "stale completion and timeout references cannot finish a later operation", ctx do
    assert :ok = Remote.command(:connect, %{"hostname" => "gateway"}, ctx.name)
    assert_receive {:executing, worker, :connect, _}
    {task, _} = :sys.get_state(ctx.remote).worker
    send(worker, {:finish, :ok})
    eventually(fn -> Remote.status(ctx.name).operation == nil end)
    assert :ok = Remote.command(:disconnect, %{}, ctx.name)
    assert_receive {:executing, next, :disconnect, _}
    send(ctx.remote, {task.ref, :ok})
    send(ctx.remote, {:timeout, task.ref})
    send(ctx.remote, {:DOWN, task.ref, :process, worker, :normal})
    assert Remote.status(ctx.name).operation == "disconnect"
    assert Process.alive?(next)
  end

  test "private queries and daemon results never enter public properties or process state", ctx do
    url = "https://login.tailscale.com/a/private-worker-token"
    Agent.update(ctx.control, &%{&1 | url: url})
    assert Remote.login_url(ctx.name) == url
    assert :ok = Remote.command(:connect, %{"hostname" => "gateway"}, ctx.name)
    assert_receive {:executing, worker, :connect, _}
    send(worker, {:finish, {:ok, url}})
    eventually(fn -> Remote.status(ctx.name).operation == nil end)
    refute inspect(:sys.get_state(ctx.remote)) =~ "private-worker-token"
    refute inspect(Remote.status(ctx.name)) =~ "private-worker-token"

    refute inspect(PropertyTable.match(Observations.table(), ["remote"])) =~
             "private-worker-token"
  end

  test "changed observations notify subscribers; unchanged polls do not", ctx do
    id = :sys.get_state(ctx.remote).id
    path = Observations.workflow("remote", id)
    # Ensure the initial value is published before changing the daemon.
    send(ctx.remote, :poll)
    Remote.status(ctx.name)
    flush_events()
    Agent.update(ctx.control, &put_in(&1.snapshot.state, "online"))
    assert_receive %PropertyTable.Event{property: ^path}, 1_000
    assert Remote.status(ctx.name).state == "online"
    refute_receive %PropertyTable.Event{property: ^path}, 40
  end

  @tag :capture_log
  test "adapter crashes and killed workers are reported by their monitors", ctx do
    assert :ok = Remote.command(:connect, %{"hostname" => "gateway"}, ctx.name)
    assert_receive {:executing, worker, :connect, _}
    send(worker, :crash)
    eventually(fn -> Remote.status(ctx.name).operation == nil end)
    assert Remote.status(ctx.name).error.code == "remote_outcome_unknown"
    refute inspect(Remote.status(ctx.name)) =~ "injected_failure"
    assert :ok = Remote.command(:disconnect, %{}, ctx.name)
    assert_receive {:executing, worker, :disconnect, _}
    Process.exit(worker, :kill)
    eventually(fn -> Remote.status(ctx.name).operation == nil end)
    assert Remote.status(ctx.name).error.code == "remote_outcome_unknown"
  end

  defp flush_events do
    receive do
      %PropertyTable.Event{} -> flush_events()
    after
      0 -> :ok
    end
  end

  defp eventually(fun, attempts \\ 100)
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
