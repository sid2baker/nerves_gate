defmodule NervesGate.FSM.FailureScenariosTest do
  use ExUnit.Case, async: false

  alias NervesGate.Cluster, as: Cluster
  alias NervesGate.SSH, as: SSH
  alias NervesGate.SubnetRouter, as: SubnetRouter
  alias NervesGate.Tailnet, as: Tailnet
  alias Tailscale.Status

  test "Tailnet loss blocks dependents and recovery uses normal reconciliation" do
    {:ok, tail} = Agent.start_link(fn -> tail_status(true) end)
    tail_status = fn -> Agent.get(tail, & &1) end
    owner = self()

    ssh =
      start_machine(
        SSH,
        SSH.new(
          tailnet: tail_status,
          starter: fn address ->
            pid =
              spawn(fn ->
                receive do
                  :stop -> :ok
                end
              end)

            send(owner, {:ssh_started, address})
            {:ok, pid}
          end,
          stopper: fn pid -> send(pid, :stop) end,
          publisher: fn _ -> :ok end,
          alarm_reporter: fn _ -> :ok end
        )
      )

    subnet =
      start_machine(
        SubnetRouter,
        SubnetRouter.new(
          tailnet: tail_status,
          apply: fn _enabled, routes -> {:ok, routes} end,
          publisher: fn _ -> :ok end,
          alarm_reporter: fn _ -> :ok end
        )
      )

    {:ok, runtime} = Agent.start_link(fn -> false end)

    cluster_ops = %{
      start: fn _ip, _cookie ->
        Agent.update(runtime, fn _ -> true end)
        {:ok, :"nervesgate@100.64.0.10"}
      end,
      stop: fn -> Agent.update(runtime, fn _ -> false end) end,
      alive?: fn -> Agent.get(runtime, & &1) end,
      connected: fn -> [] end,
      connect: fn _ -> {:error, :unused} end,
      discover: fn _ -> {:error, :unused} end
    }

    cluster =
      start_machine(
        Cluster,
        Cluster.new(
          tailnet: tail_status,
          ops: cluster_ops,
          peers: %{sync: fn _, _, _ -> :ok end, statuses: fn -> [] end},
          publisher: fn _ -> :ok end,
          alarm_reporter: fn _, _ -> :ok end
        )
      )

    assert :ok = SSH.set_enabled(true, ssh)
    assert_receive {:ssh_started, {100, 64, 0, 10}}
    assert {:ok, ["192.168.10.0/24"]} = SubnetRouter.configure(true, ["192.168.10.0/24"], subnet)
    assert :ok = Cluster.configure("field", cluster)

    assert_eventually(fn -> SSH.diagnostics(ssh).state == :listening end)
    assert SubnetRouter.diagnostics(subnet).state == :active
    assert Cluster.diagnostics(cluster).state == :online

    Agent.update(tail, fn _ -> tail_status(false) end)
    SSH.tailnet_state_changed(tail_status(false), ssh)
    SubnetRouter.tailnet_state_changed(tail_status(false), subnet)
    assert :ok = Cluster.reconcile(cluster)

    assert_eventually(fn -> SSH.diagnostics(ssh).state == :blocked end)
    assert SubnetRouter.diagnostics(subnet).state == :blocked
    assert Cluster.diagnostics(cluster).state == :blocked

    Agent.update(tail, fn _ -> tail_status(true) end)
    SSH.tailnet_state_changed(tail_status(true), ssh)
    SubnetRouter.tailnet_state_changed(tail_status(true), subnet)
    assert :ok = Cluster.reconcile(cluster)

    assert_eventually(fn -> SSH.diagnostics(ssh).state == :listening end)
    assert SubnetRouter.diagnostics(subnet).state == :active
    assert Cluster.diagnostics(cluster).state == :online
  end

  test "Internet failure does not force a usable Tailnet out of online" do
    machine =
      start_machine(
        Tailnet,
        Tailnet.new(
          enabled: true,
          read_status: fn ->
            {:ok, %Status{online: true, authenticated: true, ipv4: "100.64.0.10"}}
          end,
          read_health: fn -> {:ok, Tailscale.Health.initial()} end,
          route_status: fn -> {:ok, %{advertised: [], approved: [], primary: []}} end,
          publisher: fn _ -> :ok end,
          alarm_reporter: fn _ -> :ok end
        )
      )

    assert :ok = Tailnet.refresh(machine)
    assert Tailnet.diagnostics(machine).state == :online

    NervesGate.Internet.Alarms.report(%{online: false}, %{online: true})
    assert Tailnet.diagnostics(machine).state == :online
  after
    NervesGate.Internet.Alarms.report(%{online: true}, %{online: false})
  end

  defp start_machine(module, payload) do
    name = String.to_atom("failure_#{System.unique_integer([:positive])}")
    {:ok, machine} = module.start_link(payload: payload, name: name)
    machine
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

  defp tail_status(true) do
    %{
      online: true,
      ipv4: "100.64.0.10",
      nodes: [],
      subnet_router: %{
        advertised: ["192.168.10.0/24"],
        approved: ["192.168.10.0/24"],
        primary: [],
        error: nil
      }
    }
  end

  defp tail_status(false) do
    %{
      online: false,
      ipv4: nil,
      nodes: [],
      subnet_router: %{advertised: [], approved: [], primary: [], error: :unavailable}
    }
  end
end
