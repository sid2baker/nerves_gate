defmodule Scenarios.PluginLifecycle do
  @moduledoc "Lifecycle fault qualification using real packages, OTP, SD storage and owned QEMU."
  import ExUnit.Assertions
  alias Scenarios.{Device, ManagedPlugin}
  @app :managed_fixture

  def run(vm) do
    ManagedPlugin.prepare_storage(vm)
    token = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    metadata = "/tmp/lifecycle-metadata-#{token}/plugins.term"
    previous = Device.rpc(vm, Application, :get_env, [:nerves_gate, :plugins_metadata])
    directory = Path.join(System.tmp_dir!(), "gate-lifecycle-#{token}")
    paths = Device.rpc(vm, :code, :get_path)

    try do
      Device.rpc(vm, Application, :put_env, [:nerves_gate, :plugins_metadata, metadata])
      restart_manager(vm)
      qualify(vm, directory)
    after
      {:ok, entries} = ManagedPlugin.plugins(vm, :list, [])

      if Enum.any?(entries, &(&1.app == "managed_fixture")) do
        assert :ok = ManagedPlugin.plugins(vm, :stop, [@app])
        assert :ok = ManagedPlugin.plugins(vm, :assign_port, ["eth1", false, nil, true])
        assert :ok = ManagedPlugin.plugins(vm, :uninstall, [@app])
      end

      assert Device.rpc(vm, :code, :get_path) == paths
      assert_unloaded(vm)

      if previous,
        do: Device.rpc(vm, Application, :put_env, [:nerves_gate, :plugins_metadata, previous]),
        else: Device.rpc(vm, Application, :delete_env, [:nerves_gate, :plugins_metadata])

      restart_manager(vm)
      Device.rpc(vm, File, :rm_rf!, [Path.dirname(metadata)])
      File.rm_rf!(directory)
    end
  end

  defp qualify(vm, directory) do
    versions = [
      {"2.0.0", []},
      {"2.1.0", []},
      {"2.2.0", [health: :fail]},
      {"2.3.0", [preload: :fail]},
      {"2.4.0", [start: :fail]},
      {"2.5.0", [health: :timeout]},
      {"2.6.0", [health: :commit_failure]}
    ]

    packages =
      Map.new(versions, fn {version, options} ->
        {version, ManagedPlugin.upload(vm, directory, version, options)}
      end)

    try do
      assert {:ok, _} = ManagedPlugin.plugins(vm, :install, [packages["2.0.0"]])
      assert :ok = ManagedPlugin.plugins(vm, :start, [@app])
      assert_events(vm)
      assert_generation_cleanup(vm)
      assert :ok = ManagedPlugin.plugins(vm, :stop, [@app])

      assert {:error, {:rolled_back, _}} =
               ManagedPlugin.plugins(vm, :upgrade, [packages["2.2.0"]])

      assert %{active_version: "2.0.0", running?: false, enabled: false} = active(vm)
      assert_unloaded(vm)
      assert :ok = ManagedPlugin.plugins(vm, :start, [@app])
      assert :ok = ManagedPlugin.plugins(vm, :upgrade, [packages["2.1.0"]])
      assert active(vm).active_version == "2.1.0"

      for version <- ~w(2.2.0 2.3.0 2.4.0 2.5.0 2.6.0) do
        generation = active(vm).generation

        assert {:error, {:rolled_back, _}} =
                 ManagedPlugin.plugins(vm, :upgrade, [packages[version]])

        assert %{active_version: "2.1.0", running?: true} = active(vm)
        assert active(vm).generation > generation
      end

      assert_controller_interruption(vm, directory)
      assert_immutable(vm, directory)
      assert_corrupt_previous(vm)
      assert_failed_rollback(vm, directory)

      for _ <- 1..3 do
        assert :ok = ManagedPlugin.plugins(vm, :rollback, [@app])
        assert :ok = ManagedPlugin.plugins(vm, :stop, [@app])
        assert_unloaded(vm)
        assert :ok = ManagedPlugin.plugins(vm, :start, [@app])
      end

      restart_manager(vm)
      assert active(vm).running?
      assert_cleanup_failure(vm)
      assert_modified_content(vm)
    after
      Enum.each(Map.values(packages), &Device.rpc(vm, File, :rm, [&1]))
    end
  end

  defp assert_events(vm) do
    client = ManagedPlugin.main(vm)

    assert {:ok, _} =
             ManagedPlugin.call(vm, client, NervesGateSDK.Storage, :data_dir, [:managed_fixture])

    assert {:error, :not_owner} =
             ManagedPlugin.call(vm, client, NervesGateSDK.Storage, :data_dir, [:another_app])

    Device.await(vm, "managed startup callback receives typed SDK events", fn _ ->
      events = Device.rpc(vm, GenServer, :call, [client, :events])
      Enum.any?(events, &match?(%NervesGateSDK.Events.Event{topic: :system}, &1))
    end)
  end

  defp assert_generation_cleanup(vm) do
    previous = Device.status(vm).network.desired

    Scenarios.Device.save(
      vm,
      Map.put(Scenarios.Device.settings("eth0"), "eth1", %{
        "role" => "plugin",
        "address" => nil
      })
    )

    # Local claims need an exclusive assignment; changing it stops the plugin.
    assert :ok =
             ManagedPlugin.plugins(vm, :assign_port, ["eth1", true, "managed_fixture", true])

    assert :ok = ManagedPlugin.plugins(vm, :start, [@app])
    client = ManagedPlugin.main(vm)
    {:ok, scope} = Device.rpc(vm, NervesGate.Plugins.Owner, :resolve, [client])

    assert {:ok, ref} =
             ManagedPlugin.call(vm, client, NervesGateSDK.Network, :claim_local, [
               "eth1",
               "10.44.0.2",
               24
             ])

    assert :ok = ManagedPlugin.plugins(vm, :restart, [@app])
    refute Device.rpc(vm, NervesGate.Plugins.Owner, :valid?, [scope])
    refute Device.rpc(vm, :erlang, :is_process_alive, [client])
    assert Device.status(vm).network.local == nil

    assert {:error, "not_owner"} =
             ManagedPlugin.call(
               vm,
               ManagedPlugin.main(vm),
               NervesGateSDK.Network,
               :release_local,
               [ref]
             )

    assert :ok =
             ManagedPlugin.call(vm, ManagedPlugin.main(vm), NervesGateSDK.Events, :subscribe, [
               :network
             ])

    assert_inflight_cleanup(vm)
    assert :ok = ManagedPlugin.plugins(vm, :assign_port, ["eth1", false, nil, true])
    assert :ok = ManagedPlugin.plugins(vm, :start, [@app])

    restore =
      if previous["mode"] == "unconfigured", do: Scenarios.Device.settings("eth0"), else: previous

    Scenarios.Device.save(vm, restore)
  end

  defp assert_inflight_cleanup(vm) do
    interface = {:via, Registry, {VintageNet.Interface.Registry, "eth1"}}
    client = ManagedPlugin.main(vm)

    # Draining the previous lease reconfigures eth1; a claim needs it settled
    # and unaddressed before its interface process is suspended.
    Device.await(vm, "assigned LAN settled before the in-flight claim", fn status ->
      Enum.any?(
        status.connections.ports,
        &match?(
          %{name: "eth1", present: true, state: :configured, master: nil, addresses: []},
          &1
        )
      )
    end)

    assert :ok = Device.rpc(vm, :sys, :suspend, [interface])

    task =
      Task.async(fn ->
        try do
          ManagedPlugin.call(vm, client, NervesGateSDK.Network, :claim_local, [
            "eth1",
            "10.45.0.2",
            24
          ])
        catch
          :exit, _ -> :caller_stopped
        end
      end)

    try do
      Device.await(vm, "managed claim is admitted before owner stops", fn status ->
        status.network.local != nil and status.network.local.phase == :claim
      end)

      assert {:error, _} = ManagedPlugin.plugins(vm, :stop, [@app])
      assert {:error, :plugins_blocked} = ManagedPlugin.plugins(vm, :start, [@app])
    after
      Device.rpc(vm, :sys, :resume, [interface])
      Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill)
    end

    Device.await(
      vm,
      "late claim completion drains instead of granting a stale lease",
      &(&1.network.local == nil),
      75_000
    )

    assert :ok = ManagedPlugin.plugins(vm, :stop, [@app])
    assert :ok = ManagedPlugin.plugins(vm, :start, [@app])
  end

  defp assert_controller_interruption(vm, directory) do
    package = ManagedPlugin.upload(vm, directory, "2.7.0", health: :hold)

    try do
      assert {:ok, _} = ManagedPlugin.plugins(vm, :install, [package])
      request = :gen_server.send_request({NervesGate.Plugins, vm.node}, {:upgrade, package})

      Device.await(vm, "candidate health phase before controller interruption", fn _ ->
        is_pid(Device.rpc(vm, Process, :whereis, [ManagedFixture.Health]))
      end)

      generation = active(vm).generation
      restart_manager(vm)
      assert {:error, _} = :gen_server.receive_response(request, 1_000)
      assert active(vm).active_version == "2.1.0"
      assert active(vm).running?
      assert active(vm).generation > generation
      assert Device.rpc(vm, Process, :whereis, [ManagedFixture.Health]) == nil
    after
      Device.rpc(vm, File, :rm, [package])
    end
  end

  defp assert_immutable(vm, directory) do
    package = ManagedPlugin.upload(vm, directory, "2.0.0", health: :fail)

    try do
      assert {:error, :artifact_conflict} = ManagedPlugin.plugins(vm, :install, [package])
      assert active(vm).active_version == "2.1.0"
    after
      Device.rpc(vm, File, :rm, [package])
    end
  end

  defp assert_corrupt_previous(vm) do
    archive = artifact(vm, "2.0.0", "package.ez")
    {:ok, bytes} = Device.rpc(vm, File, :read, [archive])
    client = ManagedPlugin.main(vm)

    try do
      assert :ok = Device.rpc(vm, File, :write, [archive, "modified archive"])
      assert {:error, :artifact_modified} = ManagedPlugin.plugins(vm, :rollback, [@app])
      assert ManagedPlugin.main(vm) == client
      assert active(vm).running?
    after
      Device.rpc(vm, File, :write, [archive, bytes])
    end
  end

  defp assert_failed_rollback(vm, directory) do
    archive = artifact(vm, active(vm).active_version, "package.ez")
    {:ok, bytes} = Device.rpc(vm, File, :read, [archive])
    package = ManagedPlugin.upload(vm, directory, "2.8.0", health: :corrupt_previous)

    try do
      assert {:error, {:rollback_failed, _, :artifact_modified}} =
               ManagedPlugin.plugins(vm, :upgrade, [package])

      assert {:error, :plugins_blocked} = ManagedPlugin.plugins(vm, :start, [@app])
      refute active(vm).running?
    after
      Device.rpc(vm, File, :write, [archive, bytes])
      Device.rpc(vm, File, :rm, [package])
    end

    assert :ok = ManagedPlugin.plugins(vm, :stop, [@app])
    assert :ok = ManagedPlugin.plugins(vm, :start, [@app])
    assert active(vm).active_version == "2.1.0"
  end

  defp assert_modified_content(vm) do
    assert :ok = ManagedPlugin.plugins(vm, :stop, [@app])
    version = active(vm).active_version
    archive = artifact(vm, version, "package.ez")
    {:ok, bytes} = Device.rpc(vm, File, :read, [archive])

    try do
      Device.rpc(vm, File, :write, [archive, bytes <> "trailing corruption"])
      assert {:error, :artifact_modified} = ManagedPlugin.plugins(vm, :start, [@app])
      assert_unloaded(vm)
    after
      Device.rpc(vm, File, :write, [archive, bytes])
    end

    content =
      artifact(
        vm,
        version,
        "content/managed_fixture-#{version}/ebin/Elixir.ManagedFixture.Client.beam"
      )

    {:ok, beam} = Device.rpc(vm, File, :read, [content])

    try do
      Device.rpc(vm, File, :write, [content, "not the registered BEAM"])
      assert {:error, :artifact_modified} = ManagedPlugin.plugins(vm, :start, [@app])
      assert_unloaded(vm)
    after
      Device.rpc(vm, File, :write, [content, beam])
    end

    assert :ok = ManagedPlugin.plugins(vm, :start, [@app])
  end

  defp assert_cleanup_failure(vm) do
    pid = Device.rpc(vm, :erlang, :spawn, [ManagedFixture.Hold, :wait, []])

    Device.await(vm, "external fixture holds code without being force-killed", fn _ ->
      Device.rpc(vm, Process, :info, [pid, :current_function]) ==
        {:current_function, {ManagedFixture.Hold, :wait, 0}}
    end)

    try do
      assert {:error, _} = ManagedPlugin.plugins(vm, :stop, [@app])
      assert Device.rpc(vm, :erlang, :is_process_alive, [pid])
      assert {:error, :plugins_blocked} = ManagedPlugin.plugins(vm, :start, [@app])
    after
      Device.rpc(vm, :erlang, :send, [pid, :release])
    end

    Device.await(vm, "external fixture exits its old code", fn _ ->
      not Device.rpc(vm, :erlang, :is_process_alive, [pid])
    end)

    assert :ok = ManagedPlugin.plugins(vm, :stop, [@app])
    assert_unloaded(vm)
    assert :ok = ManagedPlugin.plugins(vm, :start, [@app])
  end

  defp artifact(vm, version, relative) do
    {:ok, root} = Device.rpc(vm, NervesGate.Storage, :plugins_dir)
    Path.join([root, "managed_fixture", version, relative])
  end

  defp active(vm) do
    {:ok, entries} = ManagedPlugin.plugins(vm, :list, [])
    Enum.find(entries, &(&1.app == "managed_fixture")) || flunk("Managed fixture is missing")
  end

  defp assert_unloaded(vm) do
    refute :managed_fixture in Enum.map(
             Device.rpc(vm, Application, :loaded_applications),
             &elem(&1, 0)
           )

    for module <- [
          ManagedFixture.Application,
          ManagedFixture.Client,
          ManagedFixture.Preload,
          ManagedFixture.Hold
        ] do
      assert Device.rpc(vm, :code, :is_loaded, [module]) == false
      refute Device.rpc(vm, :erlang, :check_old_code, [module])
    end
  end

  defp restart_manager(vm) do
    assert :ok =
             Device.rpc(vm, Supervisor, :terminate_child, [
               NervesGate.Supervisor,
               NervesGate.Plugins
             ])

    assert {:ok, _} =
             Device.rpc(vm, Supervisor, :restart_child, [
               NervesGate.Supervisor,
               NervesGate.Plugins
             ])

    Device.await(
      vm,
      "plugin ownership reconciled after manager restart",
      fn _ ->
        state = Device.rpc(vm, :sys, :get_state, [NervesGate.Plugins])
        state.restored? and state.job == nil and state.blocked == nil
      end,
      90_000
    )
  end
end
