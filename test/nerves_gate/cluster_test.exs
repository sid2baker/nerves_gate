defmodule NervesGate.ClusterTest do
  use ExUnit.Case

  alias NervesGate.Cluster

  setup do
    owner = self()
    {:ok, tailnet} = Agent.start_link(fn -> offline() end)
    {:ok, runtime} = Agent.start_link(fn -> %{alive: false, connected: []} end)

    {:ok, peer_behavior} =
      Agent.start_link(fn ->
        %{
          discover: fn _ipv4 -> {:error, :unused} end,
          connect: fn _ipv4 -> {:error, :unused} end
        }
      end)

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
      connect: fn ipv4 -> Agent.get(peer_behavior, & &1.connect).(ipv4) end,
      discover: fn ipv4 -> Agent.get(peer_behavior, & &1.discover).(ipv4) end
    }

    name = String.to_atom("cluster_machine_#{System.unique_integer([:positive])}")

    payload =
      Cluster.new(
        tailnet: fn -> Agent.get(tailnet, & &1) end,
        ops: ops,
        publisher: fn status -> send(owner, {:published_cluster, status}) end,
        alarm_reporter: fn _enabled, _broken -> :ok end,
        retry_delay: 1
      )

    {:ok, machine} = Cluster.start_link(payload: payload, name: name)
    %{machine: machine, tailnet: tailnet, runtime: runtime, peer_behavior: peer_behavior}
  end

  test "one Cluster process owns distribution and peer reconciliation" do
    assert {:ok, {_flags, children}} = NervesGate.Backend.Owners.init([])
    assert Enum.count(children, &(&1.id == NervesGate.Cluster)) == 1
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

  test "changing groups restarts distribution with the new cookie", context do
    Agent.update(context.tailnet, fn _ -> online("100.64.0.10") end)
    assert :ok = Cluster.configure("field", context.machine)
    assert_receive {:start, "100.64.0.10", :field}

    assert :ok = Cluster.configure("other", context.machine)
    assert_receive :stop
    assert_receive {:start, "100.64.0.10", :other}
    assert Cluster.status(context.machine).group == "other"
  end

  test "configuration acknowledges intent before a slow distribution restart", context do
    owner = self()
    Agent.update(context.tailnet, fn _ -> online("100.64.0.10") end)
    assert :ok = Cluster.configure("field", context.machine)
    assert_receive {:start, "100.64.0.10", :field}

    state = :sys.get_state(context.machine)

    blocking_stop = fn ->
      send(owner, {:distribution_stopping, self()})

      receive do
        :continue ->
          Agent.update(context.runtime, &%{&1 | alive: false, connected: []})
          :ok
      end
    end

    :sys.replace_state(context.machine, &put_in(&1, [:ops, :stop], blocking_stop))

    assert :ok = Cluster.configure("other", context.machine)
    assert_receive {:distribution_stopping, cluster_owner}
    send(cluster_owner, :continue)

    assert_eventually(fn -> Cluster.status(context.machine).group == "other" end)
    :sys.replace_state(context.machine, &put_in(&1, [:ops, :stop], state.ops.stop))
  end

  test "same-group candidates are discovered and connected without peer processes", context do
    node = :"nervesgate@100.64.0.11"

    Agent.update(context.peer_behavior, fn _ ->
      %{
        discover: fn _ipv4 -> {:ok, "field"} end,
        connect: fn _ipv4 ->
          Agent.update(context.runtime, &%{&1 | connected: [node]})
          {:ok, node}
        end
      }
    end)

    Agent.update(context.tailnet, fn _ -> online("100.64.0.10", [candidate()]) end)
    assert :ok = Cluster.configure("field", context.machine)

    assert_eventually(fn ->
      match?([%{group: "field", connected: true}], Cluster.status(context.machine).candidates)
    end)
  end

  test "one slow candidate does not block another candidate", context do
    owner = self()
    fast_node = :"nervesgate@100.64.0.12"

    Agent.update(context.peer_behavior, fn _ ->
      %{
        discover: fn
          "100.64.0.11" ->
            send(owner, {:slow_discovery, self()})

            receive do
              :continue -> {:ok, "field"}
            end

          "100.64.0.12" ->
            {:ok, "field"}
        end,
        connect: fn
          "100.64.0.12" ->
            Agent.update(context.runtime, &%{&1 | connected: [fast_node]})
            {:ok, fast_node}

          _other ->
            {:error, :unused}
        end
      }
    end)

    nodes = [candidate(), candidate("100.64.0.12", "nervesgate-m03")]
    Agent.update(context.tailnet, fn _ -> online("100.64.0.10", nodes) end)
    assert :ok = Cluster.configure("field", context.machine)
    assert_receive {:slow_discovery, slow_worker}

    assert_eventually(fn -> fast_node in Agent.get(context.runtime, & &1.connected) end)
    send(slow_worker, :continue)
  end

  test "foreign candidates are visible but never connected", context do
    owner = self()

    Agent.update(context.peer_behavior, fn _ ->
      %{
        discover: fn _ipv4 -> {:ok, "other"} end,
        connect: fn _ipv4 ->
          send(owner, :unexpected_connect)
          {:error, :foreign}
        end
      }
    end)

    Agent.update(context.tailnet, fn _ -> online("100.64.0.10", [candidate()]) end)
    assert :ok = Cluster.configure("field", context.machine)

    assert_eventually(fn ->
      match?([%{group: "other", connected: false}], Cluster.status(context.machine).candidates)
    end)

    refute_receive :unexpected_connect
  end

  test "peer failures retain bounded retry diagnostics", context do
    Agent.update(context.peer_behavior, fn _ ->
      %{
        discover: fn _ipv4 -> {:error, :timeout} end,
        connect: fn _ipv4 -> {:error, :unused} end
      }
    end)

    Agent.update(context.tailnet, fn _ -> online("100.64.0.10", [candidate()]) end)
    assert :ok = Cluster.configure("field", context.machine)

    assert_eventually(fn ->
      match?(
        [%{last_error: %{kind: :discovery_failed, reason: :timeout}}],
        Cluster.status(context.machine).candidates
      )
    end)

    assert %{state: :backoff, retry_at: retry_at} =
             Cluster.diagnostics(context.machine).peers["100.64.0.11"]

    assert is_integer(retry_at)
  end

  test "cluster group validation accepts clearing and rejects malformed names" do
    assert {:ok, nil} = NervesGate.Cluster.Group.validate(nil)
    assert {:error, :invalid_cluster_group} = NervesGate.Cluster.Group.validate("bad group")
  end

  defp drain_published(statuses \\ []) do
    receive do
      {:published_cluster, status} -> drain_published([status | statuses])
    after
      0 -> Enum.reverse(statuses)
    end
  end

  defp offline, do: %{online: false, ipv4: nil, nodes: []}
  defp online(ipv4, nodes \\ []), do: %{online: true, ipv4: ipv4, nodes: nodes}

  defp candidate(ipv4 \\ "100.64.0.11", hostname \\ "nervesgate-m02") do
    %{hostname: hostname, ipv4: ipv4, online: true, self: false}
  end

  defp assert_eventually(predicate, attempts \\ 100) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not converge")

      true ->
        Process.sleep(10)
        assert_eventually(predicate, attempts - 1)
    end
  end
end
