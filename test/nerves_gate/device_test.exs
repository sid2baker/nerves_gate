defmodule NervesGate.DeviceTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Config, Device, Network}
  alias NervesGate.Network.Host
  @moduletag :tmp_dir

  @static %{
    "ip_method" => "static",
    "static_ip" => "192.168.20.2",
    "subnet_mask" => "255.255.255.0",
    "gateway" => nil
  }

  defmodule Adapter do
    @behaviour NervesGate.Network
    def apply_config(config, agent) do
      %{host: host, fail: fail} = Agent.get(agent, & &1)
      Agent.update(agent, &Map.update!(&1, :attempts, fn n -> n + 1 end))
      if fail, do: {:error, :offline}, else: Host.apply_config(config, host)
    end

    def snapshot(agent), do: Host.snapshot(Agent.get(agent, & &1.host))
  end

  setup %{tmp_dir: dir} do
    host = start_supervised!({Host, name: nil})
    adapter = start_supervised!({Agent, fn -> %{host: host, fail: false, attempts: 0} end})

    opts = [
      name: {:global, {__MODULE__, make_ref()}},
      path: Path.join(dir, "nerves_gate.json"),
      adapter: {Adapter, adapter},
      poll_ms: 10,
      trial_ms: 5_000
    ]

    network = start_supervised!({Network, opts})
    device_opts = [name: nil, network: opts[:name], topic: "device:#{dir}"]
    device = start_supervised!({Device, device_opts})
    Device.subscribe(device)
    Device.projection(device)
    flush_projections()

    %{
      device: device,
      network: network,
      host: host,
      adapter: adapter,
      opts: opts,
      device_opts: device_opts,
      path: opts[:path]
    }
  end

  test "one versioned, JSON-encodable projection exposes state and action reasons", ctx do
    projection = Device.projection(ctx.device)
    assert projection.version == 1
    assert projection.network.desired == Config.defaults()["network"]
    assert projection.network.pending == nil
    assert projection.network.observed.simulated
    assert projection.actions["network.propose"].enabled
    refute projection.actions["network.confirm"].enabled
    assert projection.actions["network.confirm"].reason.code == "no_matching_trial"
    assert projection.actions["network.confirm"].required == ["trial_id"]
    assert Jason.decode!(Jason.encode!(projection))["revision"] == projection.revision
    assert Device.projection(ctx.device) == projection
    refute_receive {:device, _}, 30
  end

  test "validation and malformed commands have no effects", ctx do
    before = Agent.get(ctx.adapter, & &1.attempts)
    projection = Device.projection(ctx.device)

    assert {:ok, %{result: %{network: @static}, projection: ^projection}} =
             dispatch(ctx, "network.validate", %{"network" => @static})

    for {action, params, code} <- [
          {"network.validate", %{"network" => %{"ip_method" => "bad"}}, "invalid_parameters"},
          {"network.propose", %{"network" => @static, "extra" => true}, "invalid_parameters"},
          {"network.propose", nil, "invalid_parameters"},
          {"network.propose", %{network: @static}, "invalid_parameters"},
          {"network.propose", %{"network" => self()}, "invalid_parameters"},
          {"network.propose", %{"network" => make_ref()}, "invalid_parameters"},
          {"network.propose", %{"network" => %URI{scheme: "http"}}, "invalid_parameters"},
          {"network.propose", %{"network" => [1 | :invalid]}, "invalid_parameters"},
          {"network.propose", %{"network" => <<255>>}, "invalid_parameters"},
          {"arbitrary.module.call", %{}, "unknown_action"},
          {nil, %{}, "unknown_action"}
        ] do
      assert {:error, %{error: %{code: ^code}, projection: ^projection}} =
               dispatch(ctx, action, params)
    end

    assert Agent.get(ctx.adapter, & &1.attempts) == before
    refute File.exists?(ctx.path)
  end

  test "commands publish the same projection and persist only after confirmation", ctx do
    assert {:ok, %{result: %{trial_id: id}, projection: trial}} =
             dispatch(ctx, "network.propose", %{"network" => @static})

    assert trial.network.pending.id == id
    assert trial.network.pending.network == @static
    assert trial.network.desired == Config.defaults()["network"]
    assert trial.network.observed.bridge.method == "static"
    assert trial.actions["network.confirm"].enabled
    refute trial.actions["network.propose"].enabled
    assert_receive {:device, ^trial}
    assert {:ok, config} = Config.load(ctx.path)
    assert config == Config.defaults()

    assert {:ok, %{projection: saved}} = dispatch(ctx, "network.confirm", %{"trial_id" => id})
    assert saved.network.desired == @static
    assert saved.network.pending == nil
    assert saved.network.setup_completed
    assert saved.revision != trial.revision
    assert Device.projection(ctx.device) == saved
    assert_receive {:device, ^saved}
    assert {:ok, config} = Config.load(ctx.path)
    assert config["network"] == @static
  end

  test "concurrent clients cannot start overlapping trials", ctx do
    results =
      for _ <- 1..2 do
        Task.async(fn -> dispatch(ctx, "network.propose", %{"network" => @static}) end)
      end
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %{error: %{code: "trial_in_progress"}}}, &1)) == 1
  end

  test "stale revisions and stale trial IDs cannot affect a later trial", ctx do
    revision = Device.projection(ctx.device).revision
    {:ok, %{result: %{trial_id: old}}} = dispatch(ctx, "network.propose", %{"network" => @static})
    assert {:ok, _} = dispatch(ctx, "network.cancel", %{"trial_id" => old})
    before = Agent.get(ctx.adapter, & &1.attempts)

    assert {:error, %{error: %{code: "stale_revision"}}} =
             Device.dispatch("network.propose", %{"network" => @static},
               server: ctx.device,
               expected_revision: revision
             )

    assert Agent.get(ctx.adapter, & &1.attempts) == before

    {:ok, %{result: %{trial_id: current}}} =
      dispatch(ctx, "network.propose", %{"network" => @static})

    for action <- ["network.confirm", "network.cancel"] do
      assert {:error, %{error: %{code: "no_matching_trial"}}} =
               dispatch(ctx, action, %{"trial_id" => old})
    end

    assert Device.projection(ctx.device).network.pending.id == current
    assert {:ok, _} = dispatch(ctx, "network.confirm", %{"trial_id" => current})

    assert {:error, %{error: %{code: "no_matching_trial"}}} =
             dispatch(ctx, "network.confirm", %{"trial_id" => current})
  end

  test "readiness is rechecked by the executor even when the projection showed enabled", ctx do
    {:ok, %{result: %{trial_id: id}, projection: trial}} =
      dispatch(ctx, "network.propose", %{"network" => @static})

    assert trial.actions["network.confirm"].enabled

    Host.simulate(
      %{ports: [%{name: "eth0", present: true, link: false, master: "br0"}]},
      ctx.host
    )

    assert {:error, %{error: %{code: "not_connected"}, projection: projection}} =
             dispatch(ctx, "network.confirm", %{"trial_id" => id})

    refute projection.actions["network.confirm"].enabled
    assert projection.actions["network.cancel"].enabled
    assert projection.network.pending.id == id
    assert {:ok, _} = dispatch(ctx, "network.cancel", %{"trial_id" => id})
  end

  test "late confirmation is rejected even before the expiry message is processed", ctx do
    {:ok, %{result: %{trial_id: id}}} = dispatch(ctx, "network.propose", %{"network" => @static})

    :sys.replace_state(ctx.network, fn state ->
      put_in(state.trial.deadline, System.monotonic_time(:millisecond) - 1)
    end)

    assert {:error, %{error: %{code: "expired"}, projection: projection}} =
             dispatch(ctx, "network.confirm", %{"trial_id" => id})

    assert projection.network.pending == nil
    assert projection.network.desired == Config.defaults()["network"]
    assert Host.snapshot(ctx.host).bridge.method == "dhcp"
  end

  test "apply failure rejects the command and blocks new trials until recovery", ctx do
    Agent.update(ctx.adapter, &%{&1 | fail: true})

    assert {:error, %{error: %{code: "apply_failed"}, projection: projection}} =
             dispatch(ctx, "network.propose", %{"network" => @static})

    assert projection.network.pending == nil
    assert projection.network.recovering
    assert projection.actions["network.propose"].reason.code == "recovery_in_progress"
    assert {:ok, config} = Config.load(ctx.path)
    assert config == Config.defaults()

    assert {:error, %{error: %{code: "recovery_in_progress"}}} =
             dispatch(ctx, "network.propose", %{"network" => @static})

    Agent.update(ctx.adapter, &%{&1 | fail: false})
    eventually(fn -> Device.projection(ctx.device).actions["network.propose"].enabled end)
    assert Host.snapshot(ctx.host).bridge.method == "dhcp"
  end

  test "observations notify clients, but queued old network messages cannot rewind state", ctx do
    old = Network.status(ctx.network)
    Host.simulate(%{ports: [%{name: "eth0", present: false, link: false, master: nil}]}, ctx.host)
    assert_receive {:device, projection}
    refute hd(projection.network.observed.ports).present
    send(ctx.device, {:network, old})
    assert Device.projection(ctx.device) == projection
  end

  test "trial rollback runs while the decision gateway is stopped; restart rehydrates it", ctx do
    # Shorten just this trial, leaving the network's real timer responsible for expiry.
    :sys.replace_state(ctx.network, &%{&1 | trial_ms: 100})
    {:ok, %{projection: trial}} = dispatch(ctx, "network.propose", %{"network" => @static})
    stop_supervised!(Device)
    eventually(fn -> Network.status(ctx.network).trial == nil end)
    assert Host.snapshot(ctx.host).bridge.method == "dhcp"
    device = start_supervised!({Device, ctx.device_opts})
    projection = Device.projection(device)
    assert projection.network.pending == nil
    assert projection.network.error.code == "expired"
    assert projection.revision != trial.revision
    assert projection.network.desired == Config.defaults()["network"]
  end

  test "gateway restart does not abandon an active trial", ctx do
    {:ok, %{result: %{trial_id: id}}} = dispatch(ctx, "network.propose", %{"network" => @static})
    stop_supervised!(Device)
    device = start_supervised!({Device, ctx.device_opts})
    assert Device.projection(device).network.pending.id == id
    assert {:ok, _} = Device.dispatch("network.confirm", %{"trial_id" => id}, server: device)
  end

  test "network restart restores saved state and republishes without a client command", ctx do
    {:ok, _} = dispatch(ctx, "network.propose", %{"network" => @static})
    flush_projections()
    stop_supervised!(Network)
    projection = Device.projection(ctx.device)
    refute projection.network.available

    assert {:error, %{error: %{code: "unavailable"}}} =
             dispatch(ctx, "network.propose", %{"network" => @static})

    start_supervised!({Network, ctx.opts})
    eventually(fn -> Device.projection(ctx.device).network.available end)
    projection = Device.projection(ctx.device)
    assert projection.network.pending == nil
    assert projection.network.observed.bridge.method == "dhcp"
    assert_receive {:device, ^projection}
  end

  test "corrupt settings and restoration failure disable unsafe actions", ctx do
    stop_supervised!(Network)
    File.write!(ctx.path, "broken")
    start_supervised!({Network, ctx.opts})
    projection = Device.projection(ctx.device)
    assert projection.actions["network.propose"].reason.code == "invalid_saved_config"

    assert {:error, %{error: %{code: "invalid_saved_config"}}} =
             dispatch(ctx, "network.propose", %{"network" => @static})

    assert File.read!(ctx.path) == "broken"
    assert Jason.encode!(projection)

    stop_supervised!(Network)
    File.rm!(ctx.path)
    Agent.update(ctx.adapter, &%{&1 | fail: true})
    start_supervised!({Network, ctx.opts})

    assert Device.projection(ctx.device).actions["network.propose"].reason.code ==
             "recovery_in_progress"

    Agent.update(ctx.adapter, &%{&1 | fail: false})
    eventually(fn -> Device.projection(ctx.device).actions["network.propose"].enabled end)
  end

  test "failed persistence is a rejection, never a successful command acknowledgement", ctx do
    {:ok, %{result: %{trial_id: id}}} = dispatch(ctx, "network.propose", %{"network" => @static})
    File.rm!(ctx.path)
    File.mkdir!(ctx.path)

    assert {:error, %{error: %{code: "save_failed"}, projection: projection}} =
             dispatch(ctx, "network.confirm", %{"trial_id" => id})

    assert projection.network.pending == nil
    assert projection.network.desired == Config.defaults()["network"]
    assert Host.snapshot(ctx.host).bridge.method == "dhcp"
  end

  test "fresh evaluations leave no accumulated Runic facts in the gateway", ctx do
    workflow = :sys.get_state(ctx.device).workflow
    for _ <- 1..20, do: dispatch(ctx, "network.validate", %{"network" => @static})
    assert :sys.get_state(ctx.device).workflow == workflow
    assert Runic.Workflow.facts(workflow) == []
  end

  defp dispatch(ctx, action, params), do: Device.dispatch(action, params, server: ctx.device)

  defp flush_projections do
    receive do
      {:device, _} -> flush_projections()
    after
      0 -> :ok
    end
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, remaining - 1)
    end
  end
end
