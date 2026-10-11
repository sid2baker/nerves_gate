defmodule NervesGate.NetworkAgentTest do
  use ExUnit.Case, async: true
  alias NervesGate.{AtomicFile, Config, Network}
  alias NervesGate.Network.{Actions, Host, Plugin, Signals, Trial, TrialStore}

  @moduletag :tmp_dir
  @network %{
    "mode" => "shared",
    "equipment" => %{
      "ip_method" => "static",
      "static_ip" => "192.168.20.2",
      "subnet_mask" => "255.255.255.0",
      "gateway" => nil
    }
  }

  defmodule Controlled do
    @behaviour NervesGate.Network.Adapter
    @network %{
      "mode" => "shared",
      "equipment" => %{
        "ip_method" => "static",
        "static_ip" => "192.168.20.2",
        "subnet_mask" => "255.255.255.0",
        "gateway" => nil
      }
    }
    def snapshot({host, _}), do: Host.snapshot(host)

    def apply_config(network, {host, controls}) do
      case Agent.get(controls, & &1) do
        %{hold: true, observer: observer} when network == @network ->
          send(observer, {:applying, self()})

          receive do
            :continue -> Host.apply_config(network, host)
          end

        %{fail: true} when network == @network ->
          {:error, :injected_failure}

        _ ->
          Host.apply_config(network, host)
      end
    end
  end

  defmodule Storage do
    @behaviour AtomicFile
    defdelegate read(path), to: AtomicFile
    defdelegate remove(path), to: AtomicFile

    def write(path, data) do
      with true <- String.ends_with?(path, ".trial"),
           {:ok, %{"phase" => "confirmed"}} <- Jason.decode(data),
           true <- File.exists?(path <> ".uncertain") do
        :ok = AtomicFile.write(path, data)
        {:error, {:uncertain, :injected_directory_sync_failure}}
      else
        _ -> AtomicFile.write(path, data)
      end
    end
  end

  setup %{tmp_dir: dir} do
    host = start_supervised!({Host, name: nil})
    observer = self()

    controls =
      start_supervised!({Agent, fn -> %{hold: false, fail: false, observer: observer} end})

    opts = [
      name: nil,
      path: Path.join(dir, "settings.json"),
      adapter: {Controlled, {host, controls}},
      trial_ms: 1_000,
      poll_ms: 10,
      effect_ms: 300,
      storage: Storage
    ]

    server = start_supervised!({Network, opts})
    %{server: server, host: host, controls: controls, opts: opts, path: opts[:path]}
  end

  test "native routes validate drafts without hardware or journal effects", ctx do
    assert {:ok, @network} = Network.validate(@network, ctx.server)
    assert {:error, _} = Network.validate(%{"mode" => "wifi"}, ctx.server)
    refute File.exists?(ctx.path)
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
    assert :ok = Jido.AgentServer.await_ready(Network.agent(ctx.server))
  end

  test "schema rejection does not poison the live command queue", ctx do
    server = Network.agent(ctx.server)
    :ok = Jido.AgentServer.await_ready(server)
    signal = Jido.Signal.new!(%{type: "network.confirm", source: "/test", data: %{id: 42}})

    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             Jido.AgentServer.call(server, signal)

    assert {:ok, id} = Network.propose(@network, ctx.server)
    assert :ok = Network.cancel(id, ctx.server)
  end

  test "pure action admission rejects a conflicting trial", ctx do
    {:ok, id} = Network.propose(@network, ctx.server)

    context = %{
      agent_state: Network.Agent.new!().state,
      plugin_inputs: %{Plugin => %Jido.Plugin.Input{runtime: Network.status(ctx.server)}}
    }

    assert {:ok, %{outcome: {:error, :trial_in_progress}}} =
             Actions.Propose.run(%{network: @network, id: id}, context)
  end

  test("native route advances from live admission rather than copying event phase", ctx) do
    {:ok, id} = Network.propose(@network, ctx.server)
    safety = Network.Runtime.admission(Network.runtime(ctx.server))

    signal =
      Signals.new(
        "network.configuration.applied",
        id,
        :pending,
        safety.workflow.sequence,
        safety.workflow.incarnation
      )

    agent = Network.Agent.new!()
    assert {:ok, %{executable: Actions.Advance}} = Jido.Agent.handle_signal(signal, agent)

    context = %{
      agent_state: agent.state,
      signal: signal,
      plugin_inputs: %{Plugin => %Jido.Plugin.Input{runtime: safety}}
    }

    assert {:ok, %{phase: :awaiting_confirmation, trial_id: ^id}} =
             Actions.Advance.run(signal.data, context)
  end

  test "agent crash rolls back without restarting the safety runtime", ctx do
    {:ok, _} = Network.propose(@network, ctx.server)
    runtime = Network.runtime(ctx.server)
    agent = Network.agent(ctx.server)
    Process.exit(agent, :kill)
    eventually(fn -> Network.agent(ctx.server) != agent and restored?(ctx) end)
    assert Network.runtime(ctx.server) == runtime
    assert {:ok, nil} = TrialStore.load(ctx.path)
    assert {:ok, _} = Network.propose(@network, ctx.server)
  end

  test "runtime crash recovers the journal and restarts its dependent agent", ctx do
    {:ok, _} = Network.propose(@network, ctx.server)
    runtime = Network.runtime(ctx.server)
    agent = Network.agent(ctx.server)
    Process.exit(runtime, :kill)
    eventually(fn -> Network.runtime(ctx.server) not in [nil, runtime] end)
    eventually(fn -> Network.agent(ctx.server) not in [nil, agent] and restored?(ctx) end)
    assert {:ok, nil} = TrialStore.load(ctx.path)
  end

  test "watchdog stops a blocked apply before restoring; no orphan can apply later", ctx do
    Agent.update(ctx.controls, &%{&1 | hold: true})
    caller = Task.async(fn -> Network.propose(@network, ctx.server) end)
    assert_receive {:applying, worker}, 1_000
    ref = Process.monitor(worker)
    assert Network.status(ctx.server).trial != nil
    assert {:ok, record} = TrialStore.load(ctx.path)
    assert record["phase"] == "pending"
    assert {:error, :operation_timeout} = Task.await(caller)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    send(worker, :continue)
    assert restored?(ctx)
  end

  test "killing the runtime also kills its in-flight hardware worker", ctx do
    Agent.update(ctx.controls, &%{&1 | hold: true})
    caller = Task.async(fn -> Network.propose(@network, ctx.server) end)
    assert_receive {:applying, worker}, 1_000
    ref = Process.monitor(worker)
    runtime = Network.runtime(ctx.server)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    assert {:error, :outcome_unknown} = Task.await(caller)
    eventually(fn -> Network.runtime(ctx.server) not in [nil, runtime] and restored?(ctx) end)
  end

  test "trial deadline stops a blocked application independently of the agent", ctx do
    runtime = Network.runtime(ctx.server)
    :sys.replace_state(runtime, &%{&1 | trial_ms: 2_000, effect_ms: 5_000})
    Agent.update(ctx.controls, &%{&1 | hold: true})
    caller = Task.async(fn -> Network.propose(@network, ctx.server) end)
    assert_receive {:applying, worker}, 1_000
    ref = Process.monitor(worker)

    # Start the short deadline after durable prepare, not in a race with fsync.
    :sys.replace_state(runtime, fn state ->
      Process.cancel_timer(state.timer)
      timer = Process.send_after(self(), {:expire, state.trial["id"]}, 25)
      %{state | timer: timer, deadline: System.monotonic_time(:millisecond) + 25}
    end)

    assert {:error, :expired} = Task.await(caller)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert restored?(ctx)
  end

  test "agent failure during an effect cannot leave its hardware worker alive", ctx do
    Agent.update(ctx.controls, &%{&1 | hold: true})
    caller = Task.async(fn -> Network.propose(@network, ctx.server) end)
    assert_receive {:applying, worker}, 1_000
    ref = Process.monitor(worker)
    Process.exit(Network.agent(ctx.server), :kill)
    assert {:error, :outcome_unknown} = Task.await(caller)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    eventually(fn -> restored?(ctx) end)
    assert {:ok, nil} = TrialStore.load(ctx.path)
  end

  test "a failed prepare never changes hardware or acknowledges a trial", ctx do
    File.mkdir!(ctx.path)
    assert {:error, {:save, _}} = Network.propose(@network, ctx.server)
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
    assert Network.status(ctx.server).recovering
    assert {:error, :recovery_in_progress} = Network.propose(@network, ctx.server)
    refute File.exists?(TrialStore.path(ctx.path))
  end

  test "adapter application failure restores the old configuration", ctx do
    Agent.update(ctx.controls, &%{&1 | fail: true})
    assert {:error, {:apply, :injected_failure}} = Network.propose(@network, ctx.server)
    assert restored?(ctx)
    assert {:ok, nil} = TrialStore.load(ctx.path)
  end

  test "an uncertain commit marker reconciles its durable decision instead of rolling back",
       ctx do
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "network:events")
    {:ok, id} = Network.propose(@network, ctx.server)
    File.write!(TrialStore.path(ctx.path) <> ".uncertain", "")
    assert {:error, :outcome_unknown} = Network.confirm(id, ctx.server)
    assert Network.status(ctx.server).trial == nil
    refute Network.status(ctx.server).recovering
    assert Network.status(ctx.server).config["network"] == @network
    assert Host.snapshot(ctx.host).bridge.method == "static"
    assert {:ok, nil} = TrialStore.load(ctx.path)
    assert_receive %Jido.Signal{type: "network.trial.confirmed", data: %{trial_id: ^id}}
    refute_receive %Jido.Signal{type: "network.trial.rolled_back", data: %{trial_id: ^id}}, 20
  end

  test "reboot reconciles a pending journal even when the primary config was corrupted", ctx do
    stop_supervised!(Network)
    record = Trial.new(Config.defaults(), @network, false, 60_000)
    assert :ok = TrialStore.prepare(record, ctx.path)
    File.write!(ctx.path, "interrupted configuration file")
    Host.apply_config(@network, ctx.host)
    server = start_supervised!({Network, ctx.opts})
    assert restored?(%{ctx | server: server})
    assert {:ok, nil} = TrialStore.load(ctx.path)
    assert {:ok, defaults} = Config.load(ctx.path)
    assert defaults == Config.defaults()
  end

  defp restored?(ctx) do
    case Network.runtime(ctx.server) do
      nil ->
        false

      _ ->
        status = Network.status(ctx.server)

        status.trial == nil and not status.recovering and
          Host.snapshot(ctx.host).bridge.method == "disabled"
    end
  catch
    :exit, _ -> false
  end

  defp eventually(fun, attempts \\ 150)
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
