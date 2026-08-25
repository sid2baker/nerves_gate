defmodule NervesGate.ClusterTest do
  use ExUnit.Case

  alias NervesGate.Cluster

  setup do
    owner = self()
    {:ok, tailnet} = Agent.start_link(fn -> offline() end)
    {:ok, runtime} = Agent.start_link(fn -> %{alive: false, connected: []} end)

    ops = %{
      start: fn ipv4, cookie ->
        send(owner, {:start, ipv4, cookie})
        Agent.update(runtime, &%{&1 | alive: true})
        {:ok, :"nervesgate@100.64.0.10"}
      end,
      stop: fn ->
        send(owner, :stop)
        Agent.update(runtime, &%{&1 | alive: false, connected: []})
        :ok
      end,
      alive?: fn -> Agent.get(runtime, & &1.alive) end,
      connected: fn -> Agent.get(runtime, & &1.connected) end,
      connect: fn _ -> {:error, :unused} end,
      discover: fn _ -> {:error, :unused} end
    }

    peers = %{sync: fn _candidates, _group, _ops -> :ok end, statuses: fn -> [] end}
    name = String.to_atom("cluster_machine_#{System.unique_integer([:positive])}")

    payload =
      Cluster.new(
        tailnet: fn -> Agent.get(tailnet, & &1) end,
        ops: ops,
        peers: peers,
        publisher: fn status -> send(owner, {:published_cluster, status}) end,
        alarm_reporter: fn _enabled, _broken -> :ok end,
        retry_delay: 1
      )

    {:ok, machine} = Cluster.start_link(payload: payload, name: name)
    %{machine: machine, tailnet: tailnet, runtime: runtime}
  end

  test "configured cluster blocks on Tailnet then reconciles online", context do
    assert :ok = Cluster.configure("field", context.machine)
    assert Cluster.diagnostics(context.machine).state == :blocked

    Agent.update(context.tailnet, fn _ -> online("100.64.0.10") end)
    assert :ok = Cluster.reconcile(context.machine)

    assert_receive {:start, "100.64.0.10", :field}
    assert Cluster.status(context.machine).online
  end

  test "periodic reconciliation preserves public online reality", context do
    Agent.update(context.tailnet, fn _ -> online("100.64.0.10") end)
    assert :ok = Cluster.configure("field", context.machine)
    drain_published()

    assert :ok = Cluster.reconcile(context.machine)
    statuses = drain_published()

    assert statuses != []
    assert Enum.all?(statuses, &(&1.state == :online and &1.online))
    assert Cluster.diagnostics(context.machine).state == :online
  end

  test "Tailnet loss blocks cluster without changing desired group", context do
    Agent.update(context.tailnet, fn _ -> online("100.64.0.10") end)
    assert :ok = Cluster.configure("field", context.machine)
    assert Cluster.status(context.machine).online

    Agent.update(context.tailnet, fn _ -> offline() end)
    assert :ok = Cluster.reconcile(context.machine)
    assert_receive :stop
    assert Cluster.diagnostics(context.machine).state == :blocked
    assert Cluster.status(context.machine).group == "field"
  end

  test "distribution failures use backoff and heal retries", context do
    state = :sys.get_state(context.machine)
    failing_ops = %{state.ops | start: fn _ip, _cookie -> {:error, :epmd} end}
    :sys.replace_state(context.machine, &%{&1 | ops: failing_ops})
    Agent.update(context.tailnet, fn _ -> online("100.64.0.10") end)

    assert :ok = Cluster.configure("field", context.machine)
    assert Cluster.diagnostics(context.machine).state == :backoff
    assert Cluster.diagnostics(context.machine).last_error == {:distribution_start_failed, :epmd}

    state = :sys.get_state(context.machine)

    good_ops = %{
      state.ops
      | start: fn _ip, _cookie ->
          Agent.update(context.runtime, &%{&1 | alive: true})
          {:ok, :"nervesgate@100.64.0.10"}
        end
    }

    :sys.replace_state(context.machine, &%{&1 | ops: good_ops})

    assert :ok = Cluster.heal(context.machine)
    assert Cluster.status(context.machine).online
  end

  test "clearing a group disables distribution" do
    assert {:ok, nil} = Cluster.validate_group(nil)
    assert {:error, :invalid_cluster_group} = Cluster.validate_group("bad group")
  end

  defp drain_published(statuses \\ []) do
    receive do
      {:published_cluster, status} -> drain_published([status | statuses])
    after
      0 -> Enum.reverse(statuses)
    end
  end

  defp offline, do: %{online: false, ipv4: nil, nodes: []}
  defp online(ipv4), do: %{online: true, ipv4: ipv4, nodes: []}
end
