defmodule NervesGate.NetworkWorkflowTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Config, Network}
  alias NervesGate.Network.Host
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

    %{server: server, host: host, adapter: adapter}
  end

  test "USB auto-save runs once, after apply completes, using current observations", ctx do
    Adapter.hold(ctx.adapter, :apply, @network)
    caller = Task.async(fn -> Network.propose(@network, ctx.server, @access) end)
    assert_receive {:blocked, :apply, worker}, 1_000
    Host.simulate(%{usb: @usb, ports: Host.snapshot(ctx.host).ports}, ctx.host)
    send(worker, :continue)
    assert {:ok, _} = Task.await(caller)
    assert Network.status(ctx.server).trial.auto_save
    assert Host.load(ctx.host) == {:ok, Config.defaults()}

    Host.simulate(%{usb: @usb}, ctx.host)
    eventually(fn -> Network.status(ctx.server).trial == nil end)
    assert Host.load(ctx.host) == {:ok, Config.from_network(@network)}

    for _ <- 1..10, do: send(ctx.server, :observations_changed)
    assert Network.status(ctx.server).phase == :idle
    assert Enum.count(Adapter.calls(ctx.adapter), &match?({:save, _}, &1)) == 1
  end

  test "observations and polling cannot auto-save a manual trial", ctx do
    {:ok, id} = Network.propose(@network, ctx.server)
    Host.simulate(%{usb: @usb}, ctx.host)
    send(ctx.server, :poll)
    send(ctx.server, :observations_changed)
    assert Network.status(ctx.server).trial.id == id
    assert Host.load(ctx.host) == {:ok, Config.defaults()}
    assert {:error, :no_matching_trial} = Network.confirm("old", ctx.server)
    assert :ok = Network.cancel(id, ctx.server)
  end

  test "polling repairs a lost observation without a separate decision process", ctx do
    Host.simulate(%{usb: @usb, ports: Host.snapshot(ctx.host).ports}, ctx.host)
    {:ok, _} = Network.propose(@network, ctx.server, @access)
    # Deliberately change the simulator without publishing an observation.
    Agent.update(ctx.host, &%{&1 | overrides: %{usb: @usb}})
    eventually(fn -> Network.status(ctx.server).trial == nil end)
    assert Network.status(ctx.server).config["setup_completed"]
  end

  test "an expired USB trial cannot save even when its apply worker reports success", ctx do
    Adapter.hold(ctx.adapter, :apply, @network)
    caller = Task.async(fn -> Network.propose(@network, ctx.server, @access) end)
    assert_receive {:blocked, :apply, worker}, 1_000
    :sys.replace_state(ctx.server, &%{&1 | deadline: System.monotonic_time(:millisecond) - 1})
    send(worker, :continue)
    assert {:error, :expired} = Task.await(caller)
    assert Host.load(ctx.host) == {:ok, Config.defaults()}
    refute Enum.any?(Adapter.calls(ctx.adapter), &match?({:save, _}, &1))
  end

  test "display expiry cannot expire a live manual trial", ctx do
    {:ok, id} = Network.propose(@network, ctx.server)

    :sys.replace_state(ctx.server, fn state ->
      %{state | trial: %{state.trial | expires_at: 0}}
    end)

    send(ctx.server, :poll)
    send(ctx.server, :observations_changed)
    assert %{trial: %{id: ^id}} = Network.status(ctx.server)
    assert Host.load(ctx.host) == {:ok, Config.defaults()}
    assert :ok = Network.confirm(id, ctx.server)
    assert Host.load(ctx.host) == {:ok, Config.from_network(@network)}
  end

  test "reconciliation expires a ready USB trial before saving despite its future display expiry",
       ctx do
    Host.simulate(%{usb: @usb, ports: Host.snapshot(ctx.host).ports}, ctx.host)
    {:ok, _} = Network.propose(@network, ctx.server, @access)

    # Make it ready and overdue before the server can process another poll.
    :sys.replace_state(ctx.server, fn state ->
      Agent.update(ctx.host, &%{&1 | overrides: %{usb: @usb}})

      %{
        state
        | deadline: System.monotonic_time(:millisecond) - 1,
          trial: %{state.trial | expires_at: System.system_time(:millisecond) + 60_000}
      }
    end)

    send(ctx.server, :observations_changed)

    eventually(fn ->
      status = Network.status(ctx.server)
      status.trial == nil and not status.recovering
    end)

    assert Host.load(ctx.host) == {:ok, Config.defaults()}
    refute Enum.any?(Adapter.calls(ctx.adapter), &match?({:save, _}, &1))
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
