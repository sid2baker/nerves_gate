defmodule NervesGate.NetworkTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Config, Network}
  alias NervesGate.Network.Host

  @static %{
    "mode" => "shared",
    "equipment" => %{
      "ip_method" => "static",
      "static_ip" => "192.168.20.2",
      "subnet_mask" => "255.255.255.0",
      "gateway" => nil
    }
  }
  alias NervesGate.TestNetworkAdapter, as: Adapter

  setup do
    host = start_supervised!({Host, name: nil})
    adapter = start_supervised!({Adapter, host: host, owner: self()})

    opts = [
      name: nil,
      adapter: {Adapter, adapter},
      poll_ms: 10,
      trial_ms: 2_000
    ]

    server = start_supervised!({Network, opts})
    %{server: server, host: host, adapter: adapter, opts: opts}
  end

  test "configuration only persists after explicit confirmation", ctx do
    assert {:ok, id} = Network.propose(@static, ctx.server)
    assert {:ok, config} = Host.load(ctx.host)
    assert config == Config.defaults()
    assert Network.status(ctx.server).ready
    assert :ok = Network.confirm(id, ctx.server)
    assert {:ok, saved} = Host.load(ctx.host)
    assert saved["network"] == @static
    assert saved["setup_completed"]
    assert {:error, :no_matching_trial} = Network.confirm(id, ctx.server)
  end

  test "unconfirmed trial expires without any browser process", ctx do
    assert {:ok, id} = Network.propose(@static, ctx.server)

    # Start the accelerated window after temporary application.
    :sys.replace_state(ctx.server, fn state ->
      Process.cancel_timer(state.timer)
      timer = Process.send_after(self(), {:expire, id}, 200)
      %{state | timer: timer, deadline: System.monotonic_time(:millisecond) + 200}
    end)

    eventually(fn ->
      status = Network.status(ctx.server)
      status.trial == nil and not status.recovering
    end)

    assert Host.snapshot(ctx.host).bridge.method == "disabled"
    assert {:ok, config} = Host.load(ctx.host)
    assert config == Config.defaults()
  end

  test "single cable and even a missing second interface work", ctx do
    Host.simulate(
      %{
        ports: [
          %{name: "eth0", present: true, link: true, master: "br0"},
          %{name: "eth1", present: false, link: false, master: nil}
        ]
      },
      ctx.host
    )

    assert {:ok, id} = Network.propose(@static, ctx.server)
    assert :ok = Network.confirm(id, ctx.server)
  end

  test "reject confirmation without a connected, correctly enslaved port", ctx do
    Host.simulate(%{ports: [%{name: "eth0", present: true, link: false, master: nil}]}, ctx.host)
    assert {:ok, id} = Network.propose(@static, ctx.server)
    assert {:error, :not_connected} = Network.confirm(id, ctx.server)
    assert :ok = Network.cancel(id, ctx.server)
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
  end

  test "reject stale addressing while a change is still being applied", ctx do
    snapshot = Host.snapshot(ctx.host)
    Host.simulate(%{bridge: %{snapshot.bridge | method: "static"}}, ctx.host)
    assert {:ok, id} = Network.propose(@static, ctx.server)
    assert {:error, :not_connected} = Network.confirm(id, ctx.server)
  end

  test "serializes browser trials and ignores stale expiry messages", ctx do
    assert {:ok, id} = Network.propose(@static, ctx.server)
    assert {:error, :trial_in_progress} = Network.propose(@static, ctx.server)
    assert {:error, :no_matching_trial} = Network.cancel("wrong", ctx.server)
    assert :ok = Network.cancel(id, ctx.server)
    assert {:ok, new_id} = Network.propose(@static, ctx.server)
    send(ctx.server, {:expire, id})
    assert Network.status(ctx.server).trial.id == new_id
    assert :ok = Network.confirm(new_id, ctx.server)
  end

  test "restart restores saved settings, never the trial", ctx do
    assert {:ok, _} = Network.propose(@static, ctx.server)
    stop_supervised!(Network)
    server = start_supervised!({Network, ctx.opts})
    assert Network.status(server).trial == nil
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
  end

  test "confirmed subsystem settings survive coordinator restart", ctx do
    assert {:ok, id} = Network.propose(@static, ctx.server)
    assert :ok = Network.confirm(id, ctx.server)
    stop_supervised!(Network)
    server = start_supervised!({Network, ctx.opts})
    assert Network.status(server).config["network"] == @static
    assert Host.snapshot(ctx.host).bridge.method == "static"
  end

  test "late confirmation is refused even before timer is processed", ctx do
    assert {:ok, id} = Network.propose(@static, ctx.server)

    :sys.replace_state(ctx.server, fn state ->
      %{state | deadline: System.monotonic_time(:millisecond) - 1}
    end)

    assert {:error, :expired} = Network.confirm(id, ctx.server)
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
  end

  test "unreadable saved settings prevent changes", ctx do
    stop_supervised!(Network)
    Adapter.fail(ctx.adapter, :load, :invalid_saved_config)
    server = start_supervised!({Network, ctx.opts})
    before = Adapter.calls(ctx.adapter)
    assert {:error, :invalid_saved_config} = Network.propose(@static, server)
    assert Adapter.calls(ctx.adapter) == before
  end

  test "rollback retries adapter failures and prevents further changes", ctx do
    stop_supervised!(Network)
    Adapter.fail(ctx.adapter, :apply, :offline)
    server = start_supervised!({Network, ctx.opts})

    assert Network.status(server).recovering
    assert {:error, :recovery_in_progress} = Network.propose(@static, server)
    eventually(fn -> Enum.count(Adapter.calls(ctx.adapter), &match?({:apply, _}, &1)) >= 3 end)
    Adapter.fail(ctx.adapter, :apply, nil)
    eventually(fn -> not Network.status(server).recovering end)
  end

  test "failed persistence rolls back and never reports success", ctx do
    assert {:ok, id} = Network.propose(@static, ctx.server)
    Adapter.fail(ctx.adapter, :save, :enospc)
    assert {:error, {:save, _}} = Network.confirm(id, ctx.server)
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
    assert Network.status(ctx.server).trial == nil
  end

  test "separate roles can be saved offline without claiming Internet or remote reachability",
       ctx do
    network = %{
      "mode" => "ports",
      "eth0" => %{"role" => "internet", "address" => NervesGate.Config.address_defaults()},
      "eth1" => %{"role" => "equipment", "address" => @static["equipment"]}
    }

    assert {:ok, id} = Network.propose(network, ctx.server)
    assert Network.status(ctx.server).ready
    assert Enum.all?(Host.snapshot(ctx.host).ports, &is_nil(&1.master))
    assert Host.snapshot(ctx.host).usb.addresses == []

    offline_ports =
      Enum.map(Host.snapshot(ctx.host).ports, fn port ->
        port = %{port | link: false}
        if port.name == "eth0", do: %{port | addresses: []}, else: port
      end)

    Host.simulate(%{ports: offline_ports}, ctx.host)
    assert :ok = Network.confirm(id, ctx.server)
    assert {:ok, saved} = Host.load(ctx.host)
    assert saved["network"] == network
  end

  test "overlapping DHCP Internet and equipment subnets block confirmation", ctx do
    equipment = %{@static["equipment"] | "static_ip" => "192.0.2.20"}

    network = %{
      "mode" => "ports",
      "eth0" => %{"role" => "internet", "address" => NervesGate.Config.address_defaults()},
      "eth1" => %{"role" => "equipment", "address" => equipment}
    }

    assert {:ok, id} = Network.propose(network, ctx.server)
    assert {:error, :not_connected} = Network.confirm(id, ctx.server)
    assert [_] = Network.conflicts(Host.snapshot(ctx.host), network)
  end

  test "USB subnet overlap is detected and USB observations survive role changes", ctx do
    usb = %{addresses: [%{address: "192.168.20.1", prefix_length: 30}]}
    Host.simulate(%{usb: usb}, ctx.host)
    assert {:ok, id} = Network.propose(@static, ctx.server)
    assert {:error, :not_connected} = Network.confirm(id, ctx.server)
    assert :ok = Network.cancel(id, ctx.server)
    assert Host.snapshot(ctx.host).usb == usb
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
