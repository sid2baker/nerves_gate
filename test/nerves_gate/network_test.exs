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
  defmodule FailingAdapter do
    @behaviour NervesGate.Network
    def apply_config(config, agent) do
      Agent.get_and_update(agent, fn state ->
        {if(state.fail, do: {:error, :offline}, else: :ok),
         %{state | attempts: [config | state.attempts]}}
      end)
    end

    def snapshot(_), do: nil
  end

  setup %{tmp_dir: dir} do
    host = start_supervised!({Host, name: nil})

    opts = [
      name: nil,
      path: Path.join(dir, "nerves_gate.json"),
      adapter: {Host, host},
      poll_ms: 10,
      trial_ms: 200
    ]

    server = start_supervised!({Network, opts})
    %{server: server, host: host, path: opts[:path], opts: opts}
  end

  @moduletag :tmp_dir

  test "configuration only persists after explicit confirmation", ctx do
    assert {:ok, id} = Network.propose(@static, ctx.server)
    assert {:ok, config} = Config.load(ctx.path)
    assert config == Config.defaults()
    assert Network.status(ctx.server).ready
    assert :ok = Network.confirm(id, ctx.server)
    assert {:ok, saved} = Config.load(ctx.path)
    assert saved["network"] == @static
    assert saved["setup_completed"]
    assert {:error, :no_matching_trial} = Network.confirm(id, ctx.server)
  end

  test "unconfirmed trial expires without any browser process", ctx do
    assert {:ok, _} = Network.propose(@static, ctx.server)
    eventually(fn -> Network.status(ctx.server).trial == nil end)
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
    assert {:ok, config} = Config.load(ctx.path)
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

  test "restart restores committed file, never the trial", ctx do
    assert {:ok, _} = Network.propose(@static, ctx.server)
    stop_supervised!(Network)
    server = start_supervised!({Network, ctx.opts})
    assert Network.status(server).trial == nil
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
  end

  test "version 1 boot preserves the shared LAN without rewriting the file", ctx do
    stop_supervised!(Network)

    old = %{
      Config.defaults()
      | "version" => 1,
        "network" => @static["equipment"],
        "setup_completed" => true
    }

    original = Jason.encode!(old)
    File.write!(ctx.path, original)
    server = start_supervised!({Network, ctx.opts})
    assert Network.status(server).config["network"] == @static
    assert Host.snapshot(ctx.host).bridge.method == "static"
    assert Enum.all?(Host.snapshot(ctx.host).ports, &(&1.master == "br0"))
    assert File.read!(ctx.path) == original
    assert {:ok, id} = Network.propose(@static, server)
    assert :ok = Network.cancel(id, server)
    assert {:ok, saved} = Config.load(ctx.path)
    assert saved["version"] == 2
    assert saved["network"] == @static
    assert saved["mobile"] == old["mobile"]
    assert saved["vpn"] == old["vpn"]
  end

  test "late confirmation is refused even before timer is processed", ctx do
    assert {:ok, id} = Network.propose(@static, ctx.server)

    :sys.replace_state(ctx.server, fn state ->
      put_in(state.trial.deadline, System.monotonic_time(:millisecond) - 1)
    end)

    assert {:error, :expired} = Network.confirm(id, ctx.server)
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
  end

  test "corrupt saved file is never silently overwritten", ctx do
    stop_supervised!(Network)
    File.write!(ctx.path, "broken")
    server = start_supervised!({Network, ctx.opts})
    assert {:error, :invalid_saved_config} = Network.propose(@static, server)
    assert File.read!(ctx.path) == "broken"
  end

  test "rollback retries adapter failures and prevents further changes", ctx do
    stop_supervised!(Network)
    agent = start_supervised!({Agent, fn -> %{fail: true, attempts: []} end})

    server =
      start_supervised!({Network, Keyword.put(ctx.opts, :adapter, {FailingAdapter, agent})})

    assert Network.status(server).recovering
    assert {:error, :recovery_in_progress} = Network.propose(@static, server)
    eventually(fn -> Agent.get(agent, &(length(&1.attempts) >= 2)) end)
    Agent.update(agent, &%{&1 | fail: false})
    eventually(fn -> not Network.status(server).recovering end)
  end

  test "failed persistence rolls back and never reports success", ctx do
    assert {:ok, id} = Network.propose(@static, ctx.server)
    File.rm!(ctx.path)
    File.mkdir!(ctx.path)
    assert {:error, {:save, _}} = Network.confirm(id, ctx.server)
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
    assert Network.status(ctx.server).trial == nil
  end

  test "separate roles can be saved offline without claiming Internet or remote reachability",
       ctx do
    network = %{
      "mode" => "ethernet",
      "internet_port" => "eth0",
      "equipment" => @static["equipment"]
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
    assert {:ok, saved} = Config.load(ctx.path)
    assert saved["network"] == network
  end

  test "overlapping DHCP Internet and equipment subnets block confirmation", ctx do
    equipment = %{@static["equipment"] | "static_ip" => "192.0.2.20"}
    network = %{"mode" => "ethernet", "internet_port" => "eth0", "equipment" => equipment}
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
