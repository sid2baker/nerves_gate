defmodule NervesGate.ObservationsTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Config, Network, Observations, Remote}

  setup do
    host = start_supervised!({Network.Host, name: nil})
    remote_host = start_supervised!({Remote.Host, name: nil})

    network =
      start_supervised!({Network, name: nil, adapter: {Network.Host, host}, poll_ms: 60_000})

    remote =
      start_supervised!({Remote, name: nil, adapter: {Remote.Host, remote_host}, poll_ms: 60_000})

    %{host: host, remote_host: remote_host, network: network, remote: remote}
  end

  test "host properties wake runtime and subscribers without waiting for reconciliation polling",
       ctx do
    :ok = Network.observe(ctx.network)
    :ok = Remote.observe(ctx.remote)
    ports = Network.Host.snapshot(ctx.host).ports |> Enum.map(&%{&1 | connection: :internet})
    :ok = Network.Host.simulate(%{ports: ports}, ctx.host)
    assert_receive %PropertyTable.Event{property: ["host", "network", _]}, 1_000
    eventually(fn -> :sys.get_state(Network.runtime(ctx.network)).observed.ports == ports end)
    :ok = Remote.Host.simulate(%{state: "online", hostname: "observable"}, ctx.remote_host)
    assert_receive %PropertyTable.Event{property: ["host", "remote", _]}, 1_000

    assert Remote.status(ctx.remote).hostname == "observable"
    refute Map.has_key?(:sys.get_state(ctx.remote), :snapshot)
  end

  test "raw interface bursts do not become Jido facts or consume command queue capacity", ctx do
    runtime = Network.runtime(ctx.network)
    agent = Network.agent(ctx.network)
    :sys.suspend(agent)

    try do
      for n <- 1..100 do
        Network.Host.simulate(%{simulated: rem(n, 2) == 0}, ctx.host)
        send(runtime, {VintageNet, ["interface", "eth0", "state"], nil, :configured, %{}})
      end

      # Reads flush the runtime mailbox, independent of a blocked agent.
      Network.status(ctx.network)
      Process.sleep(40)
      assert Process.info(agent, :message_queue_len) == {:message_queue_len, 0}
    after
      :sys.resume(agent)
    end

    settings = %{"mode" => "ports", "eth0" => nil, "eth1" => nil}
    assert {:ok, id} = Network.propose(settings, ctx.network)
    assert :ok = Network.confirm(id, ctx.network)
  end

  test "workflow properties contain metadata, not a firmware observation mirror", ctx do
    :ok = Network.observe(ctx.network)
    settings = %{"mode" => "ports", "eth0" => nil, "eth1" => nil}
    assert {:ok, id} = Network.propose(settings, ctx.network)
    properties = PropertyTable.match(Observations.table(), ["network"])
    {_, value} = Enum.find(properties, fn {_, v} -> v.trial != nil and v.trial.id == id end)
    refute Map.has_key?(value, :observed)
    assert value.trial.network == settings
    assert :ok = Network.cancel(id, ctx.network)
  end

  test "firmware subscribes to existing tables but never the private enrollment URL" do
    assert [{VintageNet, ["interface"]}] = Network.Vintage.observations(nil)
    sources = Remote.Tailscale.observations(nil)
    assert {Tailscale.Properties, ["auth", "state"]} in sources
    assert {Tailscale.Properties, ["configuration", "value"]} in sources
    refute {Tailscale.Properties, ["auth"]} in sources
    refute {Tailscale.Properties, ["auth", "url"]} in sources
  end

  test "subscription rebinding is idempotent and cleaned up by subscriber death", ctx do
    parent = self()

    pid =
      spawn(fn ->
        for _ <- 1..3, do: Network.observe(ctx.network)
        send(parent, :subscribed)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :subscribed
    registry = PropertyTable.Supervisor.registry_name(Observations.table())
    entries = Registry.lookup(registry, :subscriptions) |> Enum.filter(fn {p, _} -> p == pid end)
    assert [_, _] = entries
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    eventually(fn ->
      not Enum.any?(Registry.lookup(registry, :subscriptions), fn {p, _} -> p == pid end)
    end)
  end

  test "Internet selectors distinguish requested roles from mere link presence", ctx do
    status = Network.status(ctx.network)
    refute Observations.Network.internet(status).expected
    ports = status.observed.ports |> Enum.map(&%{&1 | connection: :internet})
    empty = %{"mode" => "ports", "eth0" => nil, "eth1" => nil}

    status = %{
      status
      | config: %{Config.defaults() | "network" => empty},
        observed: %{status.observed | ports: ports}
    }

    assert %{expected: false, online: false} = Observations.Network.internet(status)
    wan = Map.put(empty, "eth0", %{"role" => "internet", "address" => Config.address_defaults()})

    assert %{expected: true, online: true} =
             Observations.Network.internet(%{status | trial: %{network: wan}})
  end

  defp eventually(fun, remaining \\ 100)
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
