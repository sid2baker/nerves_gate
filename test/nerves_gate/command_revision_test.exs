defmodule NervesGate.CommandRevisionTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Command, Device, Network, Remote}
  @moduletag :tmp_dir
  @network %{"mode" => "ports", "eth0" => nil, "eth1" => nil}

  setup %{tmp_dir: dir} do
    host = start_supervised!({Network.Host, name: nil})
    remote_host = start_supervised!({Remote.Host, name: nil})

    network =
      start_supervised!(
        {Network, name: nil, path: Path.join(dir, "settings.json"), adapter: {Network.Host, host}}
      )

    remote = start_supervised!({Remote, name: nil, adapter: {Remote.Host, remote_host}})

    %{
      network: network,
      remote: remote,
      remote_host: remote_host,
      device: Device.new(network: network, remote: remote)
    }
  end

  test "concurrent same-revision proposals have only one winner at native admission", ctx do
    revision = Device.projection(ctx.device).revision

    results =
      for _ <- 1..2 do
        Task.async(fn ->
          Device.dispatch("network.propose", %{"network" => @network},
            server: ctx.device,
            expected_revision: revision
          )
        end)
      end
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %{error: %{code: "stale_revision"}}}, &1)) == 1
  end

  test "effect boundary rejects a once-admitted proposal after an intervening trial", ctx do
    status = Network.status(ctx.network)

    context = %{
      agent_state: Network.Agent.new!().state,
      plugin_inputs: %{Network.Plugin => %Jido.Plugin.Input{runtime: status}},
      expected_revision: status.revision
    }

    assert {:ok, %{outcome: :pending}, [effect]} =
             Network.Actions.Propose.run(%{network: @network, id: Command.id()}, context)

    {:ok, id} = Network.propose(@network, ctx.network)
    :ok = Network.cancel(id, ctx.network)

    assert {:error, :stale_revision} =
             Network.Runtime.execute(Network.runtime(ctx.network), effect, %{
               expected_revision: status.revision
             })

    assert Network.status(ctx.network).trial == nil
  end

  test "domain restart invalidates an old token even when configuration is unchanged", ctx do
    old = Network.status(ctx.network)
    runtime = Network.runtime(ctx.network)
    ref = Process.monitor(runtime)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^ref, :process, ^runtime, _}

    eventually(fn ->
      is_pid(Network.runtime(ctx.network)) and Network.runtime(ctx.network) != runtime
    end)

    assert Network.status(ctx.network).config == old.config
    assert {:error, :stale_revision} = Network.propose(@network, ctx.network, nil, old.revision)
  end

  test "unrelated remote observations do not invalidate network changes", ctx do
    revision = Device.projection(ctx.device).revision
    Remote.Host.simulate(%{hostname: "external-name"}, ctx.remote_host)
    assert Device.projection(ctx.device).revision != revision

    assert {:ok, _} =
             Device.dispatch("network.propose", %{"network" => @network},
               server: ctx.device,
               expected_revision: revision
             )
  end

  test "unrelated network trials do not invalidate remote commands", ctx do
    revision = Device.projection(ctx.device).revision
    {:ok, id} = Network.propose(@network, ctx.network)
    :ok = Network.cancel(id, ctx.network)

    assert {:ok, _} =
             Device.dispatch("remote.configure", %{"hostname" => "remote-name"},
               server: ctx.device,
               expected_revision: revision
             )
  end

  test "external daemon changes reject stale commands both at admission and effect execution",
       ctx do
    status = Remote.status(ctx.remote)

    context = %{
      agent_state: Remote.Agent.new!().state,
      plugin_inputs: %{Remote.Plugin => %Jido.Plugin.Input{runtime: status}},
      expected_revision: status.revision
    }

    assert {:ok, %{outcome: :pending}, [effect]} =
             Remote.Actions.Configure.run(
               %{params: %{"hostname" => "stale-name"}, id: Command.id()},
               context
             )

    Remote.Host.simulate(%{hostname: "external-name"}, ctx.remote_host)

    assert {:error, :stale_revision} =
             Remote.command(
               :configure,
               %{"hostname" => "stale-name"},
               ctx.remote,
               status.revision
             )

    assert {:error, :stale_revision} =
             Remote.Runtime.execute(Remote.runtime(ctx.remote), effect, %{
               expected_revision: status.revision
             })

    assert Remote.status(ctx.remote).hostname == "external-name"
    assert Remote.status(ctx.remote).operation == nil
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
