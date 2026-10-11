defmodule NervesGate.APITest do
  use ExUnit.Case, async: true
  alias NervesGate.{Config, Network}
  alias NervesGate.Network.Host
  alias NervesGate.TestNetworkAdapter, as: Adapter

  @static %{
    "mode" => "shared",
    "equipment" => %{
      "ip_method" => "static",
      "static_ip" => "192.168.20.2",
      "subnet_mask" => "255.255.255.0",
      "gateway" => nil
    }
  }

  setup do
    host = start_supervised!({Host, name: nil})
    adapter = start_supervised!({Adapter, host: host, owner: self()})

    opts = [
      name: {:global, {__MODULE__, make_ref()}},
      adapter: {Adapter, adapter},
      poll_ms: 10,
      trial_ms: 5_000
    ]

    network = start_supervised!({Network, opts})
    api = [network: opts[:name], remote: nil, indicators: nil]
    NervesGate.subscribe(api)
    NervesGate.status(api)
    flush_observations()
    %{api: api, network: network, host: host, adapter: adapter, opts: opts}
  end

  test "named actions are the public entry point, not a dispatcher or client object" do
    for {name, arity} <- [
          network_validate: 1,
          network_propose: 1,
          network_propose: 2,
          network_confirm: 1,
          network_confirm: 2,
          network_cancel: 1,
          network_cancel: 2,
          remote_connect: 1,
          remote_connect: 2,
          remote_configure: 1,
          remote_configure: 2,
          remote_disconnect: 0,
          remote_disconnect: 1,
          remote_login_url: 0,
          remote_login_url: 1,
          identify: 0,
          identify: 1,
          button_mode: 1,
          button_mode: 2,
          status: 0,
          status: 1,
          subscribe: 0,
          subscribe: 1
        ] do
      assert function_exported?(NervesGate, name, arity)
    end

    refute function_exported?(NervesGate, :dispatch, 3)
    refute function_exported?(NervesGate, :new, 1)
  end

  test "one JSON-encodable status exposes observations and action reasons", ctx do
    status = NervesGate.status(ctx.api)
    assert status.version == 2
    assert status.connections.mode == "unconfigured"
    refute status.remote_access.verified
    assert status.remote_access.state == "unavailable"
    assert status.remote_access.permitted_routes == nil
    assert status.connections.internet.health == "unverified"
    assert status.network.desired == Config.defaults()["network"]
    assert status.network.pending == nil
    assert status.network.observed.simulated
    assert status.actions["network.propose"].enabled
    refute status.actions["network.confirm"].enabled
    assert status.actions["network.confirm"].reason.code == "no_matching_trial"
    assert status.actions["network.confirm"].required == ["trial_id"]
    assert map_size(status.actions) == 14
    assert Jason.decode!(Jason.encode!(status))["version"] == 2
    refute Map.has_key?(status, :revision)
    assert NervesGate.status(ctx.api) == status
    refute_receive {:device, _}, 30
  end

  test "Internet checks are distinct from cable, address and remote readiness", ctx do
    assert {:ok, id} = NervesGate.network_propose(@static, ctx.api)
    view = NervesGate.status(ctx.api)
    assert view.connections.internet.link
    assert view.connections.internet.addressed
    assert view.connections.internet.health == "unverified"
    assert :ok = NervesGate.network_confirm(id, ctx.api)
    bridge = %{Host.snapshot(ctx.host).bridge | connection: :internet}
    Host.simulate(%{bridge: bridge}, ctx.host)
    eventually(fn -> NervesGate.status(ctx.api).connections.internet.health == "online" end)
    view = NervesGate.status(ctx.api)
    refute view.remote_access.verified
    assert view.remote_access.permitted_routes == nil
    refute view.capabilities.remote_enrollment
  end

  test "validation and malformed action arguments have no effects", ctx do
    before = Adapter.calls(ctx.adapter)
    status = NervesGate.status(ctx.api)
    assert {:ok, @static} = NervesGate.network_validate(@static)

    for invalid <- [
          %{"mode" => "bad"},
          put_in(@static, ["equipment", "static_ip"], <<255>>),
          put_in(@static, ["equipment", "nameservers"], ["1.1.1.1" | :invalid]),
          Map.put(@static, "extra", true),
          nil,
          %{network: @static},
          self(),
          make_ref(),
          %URI{scheme: "http"},
          [1 | :invalid],
          <<255>>
        ] do
      assert {:error, %{code: "invalid_parameters"}} = NervesGate.network_validate(invalid)

      assert {:error, %{code: "invalid_parameters"}} =
               NervesGate.network_propose(invalid, ctx.api)
    end

    for invalid <- [nil, 42, %{}, self()] do
      assert {:error, %{code: "invalid_parameters"}} =
               NervesGate.network_confirm(invalid, ctx.api)

      assert {:error, %{code: "invalid_parameters"}} = NervesGate.network_cancel(invalid, ctx.api)
    end

    assert NervesGate.status(ctx.api) == status
    assert Adapter.calls(ctx.adapter) == before
    assert Host.load(ctx.host) == {:ok, Config.defaults()}
  end

  test "commands return plain results and persist only after confirmation", ctx do
    assert {:ok, id} = NervesGate.network_propose(@static, ctx.api)
    assert is_binary(id)
    trial = NervesGate.status(ctx.api)
    assert trial.network.pending.id == id
    assert trial.network.pending.network == @static
    assert trial.network.desired == Config.defaults()["network"]
    assert trial.network.observed.bridge.method == "static"
    assert trial.actions["network.confirm"].enabled
    refute trial.actions["network.propose"].enabled
    assert_receive %PropertyTable.Event{}
    assert {:ok, config} = Host.load(ctx.host)
    assert config == Config.defaults()

    assert :ok = NervesGate.network_confirm(id, ctx.api)
    saved = NervesGate.status(ctx.api)
    assert saved.network.desired == @static
    assert saved.network.pending == nil
    assert saved.network.setup_completed
    assert_receive %PropertyTable.Event{}
    assert NervesGate.status(ctx.api) == saved
    assert {:ok, config} = Host.load(ctx.host)
    assert config["network"] == @static
  end

  test "concurrent clients cannot start overlapping trials", ctx do
    results =
      for _ <- 1..2 do
        Task.async(fn -> NervesGate.network_propose(@static, ctx.api) end)
      end
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %{code: "trial_in_progress"}}, &1)) == 1
  end

  test "stale trial IDs cannot affect a later trial", ctx do
    {:ok, old} = NervesGate.network_propose(@static, ctx.api)
    assert :ok = NervesGate.network_cancel(old, ctx.api)
    {:ok, current} = NervesGate.network_propose(@static, ctx.api)
    assert {:error, %{code: "no_matching_trial"}} = NervesGate.network_confirm(old, ctx.api)
    assert {:error, %{code: "no_matching_trial"}} = NervesGate.network_cancel(old, ctx.api)
    assert NervesGate.status(ctx.api).network.pending.id == current
    assert :ok = NervesGate.network_confirm(current, ctx.api)
    assert {:error, %{code: "no_matching_trial"}} = NervesGate.network_confirm(current, ctx.api)
  end

  test "readiness is rechecked even when status showed confirmation enabled", ctx do
    {:ok, id} = NervesGate.network_propose(@static, ctx.api)
    assert NervesGate.status(ctx.api).actions["network.confirm"].enabled
    Host.simulate(%{ports: [%{name: "eth0", present: true, link: true, master: nil}]}, ctx.host)
    assert {:error, %{code: "not_connected"}} = NervesGate.network_confirm(id, ctx.api)
    status = NervesGate.status(ctx.api)
    refute status.actions["network.confirm"].enabled
    assert status.actions["network.cancel"].enabled
    assert status.network.pending.id == id
    assert :ok = NervesGate.network_cancel(id, ctx.api)
  end

  test "late confirmation is rejected before the expiry message is processed", ctx do
    {:ok, id} = NervesGate.network_propose(@static, ctx.api)

    :sys.replace_state(
      Network.runtime(ctx.network),
      &%{&1 | deadline: System.monotonic_time(:millisecond) - 1}
    )

    assert {:error, %{code: "expired"}} = NervesGate.network_confirm(id, ctx.api)
    status = NervesGate.status(ctx.api)
    assert status.network.pending == nil
    assert status.network.desired == Config.defaults()["network"]
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
  end

  test "apply failure rejects the command and blocks new trials until recovery", ctx do
    Adapter.fail(ctx.adapter, :apply, :offline)
    assert {:error, %{code: "apply_failed"}} = NervesGate.network_propose(@static, ctx.api)
    status = NervesGate.status(ctx.api)
    assert status.network.pending == nil
    assert status.network.recovering
    assert status.actions["network.propose"].reason.code == "recovery_in_progress"
    assert {:ok, config} = Host.load(ctx.host)
    assert config == Config.defaults()

    assert {:error, %{code: "recovery_in_progress"}} =
             NervesGate.network_propose(@static, ctx.api)

    Adapter.fail(ctx.adapter, :apply, nil)
    eventually(fn -> NervesGate.status(ctx.api).actions["network.propose"].enabled end)
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
  end

  test "observation notifications are hints; stale payloads cannot rewind a fresh read", ctx do
    old = Network.status(ctx.network)
    Host.simulate(%{ports: [%{name: "eth0", present: false, link: false, master: nil}]}, ctx.host)
    assert_receive %PropertyTable.Event{}
    status = NervesGate.status(ctx.api)
    refute hd(status.network.observed.ports).present

    send(self(), %PropertyTable.Event{
      table: NervesGate.Properties,
      property: ["network", "stale"],
      value: old
    })

    assert NervesGate.status(ctx.api) == status
  end

  test "trial rollback outlives its caller and requires no facade process", ctx do
    task = Task.async(fn -> NervesGate.network_propose(@static, ctx.api) end)
    assert {:ok, id} = Task.await(task)
    refute Process.alive?(task.pid)

    :sys.replace_state(Network.runtime(ctx.network), fn state ->
      Process.cancel_timer(state.timer)
      timer = Process.send_after(self(), {:expire, id}, 200)
      %{state | timer: timer, deadline: System.monotonic_time(:millisecond) + 200}
    end)

    eventually(fn ->
      status = Network.status(ctx.network)
      status.trial == nil and not status.recovering
    end)

    assert Host.snapshot(ctx.host).bridge.method == "disabled"
    status = NervesGate.status(ctx.api)
    assert status.network.pending == nil
    assert status.network.error.code == "expired"
    assert status.network.desired == Config.defaults()["network"]
  end

  test "independent callers read and confirm the same authoritative trial", ctx do
    {:ok, id} = NervesGate.network_propose(@static, ctx.api)

    task =
      Task.async(fn ->
        assert NervesGate.status(ctx.api).network.pending.id == id
        NervesGate.network_confirm(id, ctx.api)
      end)

    assert :ok = Task.await(task)
  end

  test "network restart restores saved state without a client command", ctx do
    {:ok, _} = NervesGate.network_propose(@static, ctx.api)
    flush_observations()
    stop_supervised!(Network)
    refute NervesGate.status(ctx.api).network.available
    assert {:error, %{code: "unavailable"}} = NervesGate.network_propose(@static, ctx.api)
    start_supervised!({Network, ctx.opts})
    eventually(fn -> NervesGate.status(ctx.api).network.available end)
    status = NervesGate.status(ctx.api)
    assert status.network.pending == nil
    assert status.network.observed.bridge.method == "disabled"
    assert :ok = NervesGate.subscribe(ctx.api)
    assert NervesGate.status(ctx.api) == status
  end

  test "unreadable settings and restoration failure disable unsafe actions", ctx do
    stop_supervised!(Network)
    Adapter.fail(ctx.adapter, :load, :invalid_saved_config)
    start_supervised!({Network, ctx.opts})
    status = NervesGate.status(ctx.api)
    assert status.actions["network.propose"].reason.code == "invalid_saved_config"

    assert {:error, %{code: "invalid_saved_config"}} =
             NervesGate.network_propose(@static, ctx.api)

    assert Jason.encode!(status)

    stop_supervised!(Network)
    Adapter.fail(ctx.adapter, :load, nil)
    Adapter.fail(ctx.adapter, :apply, :offline)
    start_supervised!({Network, ctx.opts})

    assert NervesGate.status(ctx.api).actions["network.propose"].reason.code ==
             "recovery_in_progress"

    Adapter.fail(ctx.adapter, :apply, nil)
    eventually(fn -> NervesGate.status(ctx.api).actions["network.propose"].enabled end)
  end

  test "failed persistence is a rejection, never a successful acknowledgement", ctx do
    {:ok, id} = NervesGate.network_propose(@static, ctx.api)
    Adapter.fail(ctx.adapter, :save, :enospc)
    assert {:error, %{code: "save_failed"}} = NervesGate.network_confirm(id, ctx.api)
    status = NervesGate.status(ctx.api)
    assert status.network.pending == nil
    assert status.network.desired == Config.defaults()["network"]
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
  end

  defp flush_observations do
    receive do
      %PropertyTable.Event{} -> flush_observations()
    after
      0 -> :ok
    end
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
