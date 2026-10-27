defmodule Scenarios.Cases.Apps do
  @moduledoc false
  import ExUnit.Assertions

  def spec do
    %{
      name: "SD application install, cold upgrade, rollback and removal",
      fresh_disk: true,
      requires: %{device: [], fixture: [:qemu]}
    }
  end

  def run(%{device: vm}) do
    commission_storage(vm)
    Scenarios.ManagedApp.prepare_storage(vm)
    install_generated_app(vm)
    Scenarios.AppLifecycle.run(vm)

    # Card removal uses a disposable Linux mount inside the supervised guest. No
    # host mounts, arbitrary VMs, hardware adapters or physical cards are involved.
    mount = "/tmp/nerves-gate-apps"
    backing = "/tmp/nerves-gate-app-backing"
    for path <- [mount, backing], do: Scenarios.Device.rpc(vm, File, :mkdir_p!, [path], 30_000)
    board = Scenarios.Device.rpc(vm, Application, :fetch_env!, [:nerves_gate, :board], 30_000)

    Scenarios.Device.rpc(
      vm,
      Application,
      :put_env,
      [:nerves_gate, :board, %{board | apps_device: nil}],
      30_000
    )

    Scenarios.Device.rpc(vm, Application, :put_env, [:nerves_gate, :apps_mount, mount], 30_000)

    assert {:ok, %{available?: false}} =
             Scenarios.Device.rpc(vm, NervesGate.Storage, :status, [], 30_000)

    assert {:error, unavailable} =
             Scenarios.Device.rpc(vm, NervesGate.Plugins, :install, ["/missing.ez"], 200_000)

    assert unavailable in [:storage_unavailable, :applications_not_ready]

    {_, 0} =
      Scenarios.Device.rpc(
        vm,
        System,
        :cmd,
        ["mount", ["-t", "tmpfs", "-o", "size=32m", "tmpfs", backing]],
        30_000
      )

    assert {_, 0} = Scenarios.Device.rpc(vm, System, :cmd, ["mount", ["--bind", backing, mount]])

    await(fn ->
      state = Scenarios.Device.rpc(vm, :sys, :get_state, [NervesGate.Plugins])
      state.available? and state.restored? and state.job == nil
    end)

    try do
      first = upload(vm, "1.0.0", true)
      second = upload(vm, "1.1.0", true)
      broken = upload(vm, "1.2.0", false)
      assert {:ok, %{app: :gate_fixture, version: "1.0.0"}} = apps(vm, :install, [first])
      assert [{:gate_fixture, "1.0.0", false}] == selection(vm)

      assert {{:error, %{code: "applications_installed"}}} =
               Scenarios.Device.rpc(
                 vm,
                 NervesGate.Storage,
                 :setup,
                 [:format, nil, :erase_all_data],
                 30_000
               )

      assert :ok = apps(vm, :start, [:gate_fixture])
      assert [{:gate_fixture, "1.0.0", true}] == selection(vm)

      assert {:ok, data} =
               Scenarios.Device.rpc(vm, NervesGate.Storage, :data_dir, [:gate_fixture], 30_000)

      assert :ok =
               Scenarios.Device.rpc(
                 vm,
                 File,
                 :write,
                 [Path.join(data, "state"), "preserved"],
                 30_000
               )

      assert :ok = apps(vm, :upgrade, [second])
      assert [{:gate_fixture, "1.1.0", true}] == selection(vm)
      assert {:error, {:rolled_back, _}} = apps(vm, :upgrade, [broken])
      assert [{:gate_fixture, "1.1.0", true}] == selection(vm)
      assert :ok = apps(vm, :rollback, [:gate_fixture])
      assert [{:gate_fixture, "1.0.0", true}] == selection(vm)
      assert :ok = apps(vm, :restart, [:gate_fixture])
      assert_storage_removal(vm, backing, mount)

      assert :ok =
               Scenarios.Device.rpc(
                 vm,
                 Supervisor,
                 :terminate_child,
                 [NervesGate.Supervisor, NervesGate.Plugins],
                 30_000
               )

      assert {:ok, _} =
               Scenarios.Device.rpc(
                 vm,
                 Supervisor,
                 :restart_child,
                 [NervesGate.Supervisor, NervesGate.Plugins],
                 30_000
               )

      await(fn -> selection(vm) == [{:gate_fixture, "1.0.0", true}] end)

      assert :ok = apps(vm, :stop, [:gate_fixture])
      assert [{:gate_fixture, "1.0.0", false}] == selection(vm)

      refute :gate_fixture in Enum.map(
               Scenarios.Device.rpc(vm, Application, :loaded_applications, [], 30_000),
               &elem(&1, 0)
             )

      assert :ok = apps(vm, :start, [:gate_fixture])
      assert :ok = apps(vm, :uninstall, [:gate_fixture])
      assert [] == selection(vm)

      assert "preserved" =
               Scenarios.Device.rpc(vm, File, :read!, [Path.join(data, "state")], 30_000)

      {_, 0} = Scenarios.Device.rpc(vm, System, :cmd, ["umount", [mount]], 30_000)

      assert {:ok, %{available?: false}} =
               Scenarios.Device.rpc(vm, NervesGate.Storage, :status, [], 30_000)

      assert {:error, :storage_unavailable} =
               Scenarios.Device.rpc(vm, NervesGate.Storage, :data_dir, [:gate_fixture], 30_000)
    after
      apps(vm, :uninstall, [:gate_fixture])
      Scenarios.Device.rpc(vm, System, :cmd, ["umount", [mount]], 30_000)
      Scenarios.Device.rpc(vm, System, :cmd, ["umount", [backing]], 30_000)
      Scenarios.Device.rpc(vm, Application, :delete_env, [:nerves_gate, :apps_mount], 30_000)
      Scenarios.Device.rpc(vm, Application, :put_env, [:nerves_gate, :board, board], 30_000)

      for version <- ~w(1.0.0 1.1.0 1.2.0),
          do: Scenarios.Device.rpc(vm, File, :rm, ["/tmp/gate_fixture-#{version}.ez"], 30_000)
    end
  end

  defp assert_storage_removal(vm, backing, mount) do
    {:ok, [before]} = apps(vm, :list, [])
    assert {_, 0} = Scenarios.Device.rpc(vm, System, :cmd, ["umount", [mount]])
    await(fn -> selection(vm) == [{:gate_fixture, "1.0.0", false}] end)

    refute :gate_fixture in Enum.map(
             Scenarios.Device.rpc(vm, Application, :started_applications),
             &elem(&1, 0)
           )

    assert {_, 0} = Scenarios.Device.rpc(vm, System, :cmd, ["mount", ["--bind", backing, mount]])
    await(fn -> selection(vm) == [{:gate_fixture, "1.0.0", true}] end)
    {:ok, [after_return]} = apps(vm, :list, [])
    assert after_return.generation > before.generation
  end

  defp install_generated_app(vm) do
    dir = Path.join(System.tmp_dir!(), "gate_app_#{System.unique_integer([:positive])}")

    try do
      app = Workbench.Applications.scaffold!(Path.join(dir, "generated_fixture"), local_sdk: true)
      package = Workbench.Applications.package!(app.path)
      bytes = File.read!(package)
      remote = "/tmp/reviewed-generated-app.ez"
      storage = Scenarios.Device.rpc(vm, NervesGate.Storage, :commissioning)

      expected = %{
        app: "generated_fixture",
        version: "1.0.0",
        sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
        card_id: storage.card_id
      }

      assert :ok = Scenarios.Device.rpc(vm, File, :write, [remote, bytes])

      assert {:error, :review_changed} =
               apps(vm, :install_new, [remote, %{expected | card_id: "changed-card"}])

      assert {:ok, _} = apps(vm, :install_new, [remote, expected])
      assert {:ok, stopped} = apps(vm, :list, [])

      assert Enum.any?(
               stopped,
               &(&1.app == "generated_fixture" and &1.enabled == false and &1.running? == false)
             )

      assert {:error, :review_changed} = apps(vm, :install_new, [remote, expected])
      assert :ok = apps(vm, :uninstall, [:generated_fixture])
      assert :ok = Scenarios.Device.rpc(vm, File, :rm, [remote])
      assert {:ok, _} = Scenarios.Apps.install(vm, package)
      assert {:ok, entries} = apps(vm, :list, [])
      assert Enum.any?(entries, &(&1.app == "generated_fixture" and &1.running?))
      assert :ok = apps(vm, :uninstall, [:generated_fixture])
    after
      apps(vm, :uninstall, [:generated_fixture])
      Scenarios.Device.rpc(vm, File, :rm, ["/tmp/reviewed-generated-app.ez"])
      File.rm_rf!(dir)
    end
  end

  defp commission_storage(vm) do
    storage = fn -> Scenarios.Device.rpc(vm, NervesGate.Storage, :commissioning, [], 30_000) end
    await(fn -> storage.().present end)
    assert storage.().choice == :pending

    assert {:error, :storage_unavailable} =
             Scenarios.Device.rpc(vm, NervesGate.Storage, :root, [], 30_000)

    assert :ok = Scenarios.Device.rpc(vm, NervesGate.Storage, :setup, [:skip], 30_000)

    assert :ok =
             Scenarios.Device.rpc(
               vm,
               Supervisor,
               :terminate_child,
               [NervesGate.Supervisor, NervesGate.Storage],
               30_000
             )

    assert {:ok, _} =
             Scenarios.Device.rpc(
               vm,
               Supervisor,
               :restart_child,
               [NervesGate.Supervisor, NervesGate.Storage],
               30_000
             )

    assert storage.().choice == :skip

    id = storage.().card_id

    assert {{:error, %{code: "storage_card_changed"}}} =
             Scenarios.Device.rpc(vm, NervesGate.Storage, :setup, [:use, "stale"], 30_000)

    assert {{:error, %{code: "storage_confirmation_required"}}} =
             Scenarios.Device.rpc(vm, NervesGate.Storage, :setup, [:format, id], 30_000)

    # The preformatted QEMU card still requires a commissioning choice.
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.Storage, :setup, [:use, id], 30_000)
    await(fn -> storage.().ready end)

    assert {:ok, data} =
             Scenarios.Device.rpc(vm, NervesGate.Storage, :data_dir, [:format_fixture], 30_000)

    marker = Path.join(data, "preserve-or-erase")
    assert :ok = Scenarios.Device.rpc(vm, File, :write, [marker, "preserved"], 30_000)
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.Storage, :setup, [:skip], 30_000)

    assert :ok =
             Scenarios.Device.rpc(
               vm,
               NervesGate.Storage,
               :setup,
               [:use, storage.().card_id],
               30_000
             )

    await(fn -> storage.().ready end)
    assert "preserved" = Scenarios.Device.rpc(vm, File, :read!, [marker], 30_000)

    # Refuse the mounted firmware disk, without a platform/target switch.
    board = Scenarios.Device.rpc(vm, Application, :fetch_env!, [:nerves_gate, :board], 30_000)

    Scenarios.Device.rpc(
      vm,
      Application,
      :put_env,
      [:nerves_gate, :board, %{board | apps_device: "/dev/vda"}],
      30_000
    )

    try do
      await(fn -> storage.().card_id != id end)

      assert {{:error, %{code: "storage_in_use"}}} =
               Scenarios.Device.rpc(
                 vm,
                 NervesGate.Storage,
                 :setup,
                 [:format, storage.().card_id, :erase_all_data],
                 30_000
               )
    after
      Scenarios.Device.rpc(vm, Application, :put_env, [:nerves_gate, :board, board], 30_000)
    end

    await(fn -> storage.().filesystem == "ext4" end)
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.Storage, :setup, [:skip], 30_000)

    # Make the disposable card unprepared by clearing its ext magic. No host
    # block device is opened; setup must reject using this card without erasing.
    assert {_, 0} =
             Scenarios.Device.rpc(
               vm,
               System,
               :cmd,
               [
                 "dd",
                 ~w(if=/dev/zero of=/dev/vdb bs=1 count=2 seek=1080 conv=notrunc)
               ],
               30_000
             )

    await(fn -> storage.().filesystem == "Unknown" end)

    assert {{:error, %{code: "storage_filesystem"}}} =
             Scenarios.Device.rpc(
               vm,
               NervesGate.Storage,
               :setup,
               [:use, storage.().card_id],
               30_000
             )

    assert :ok =
             Scenarios.Device.rpc(
               vm,
               NervesGate.Storage,
               :setup,
               [:format, storage.().card_id, :erase_all_data],
               30_000
             )

    await(fn -> storage.().operation == nil end, 1_300)
    assert storage.().error == nil
    assert storage.().ready
    refute Scenarios.Device.rpc(vm, File, :exists?, [marker], 30_000)
  end

  defp selection(vm) do
    {:ok, entries} = apps(vm, :list, [])
    Enum.map(entries, &{String.to_existing_atom(&1.app), &1.active_version, &1.running?})
  end

  defp upload(vm, version, healthy?) do
    [{module, beam}] =
      Code.compile_string("""
      defmodule GateFixture do
        use Application
        def start(_, _), do: Supervisor.start_link([], strategy: :one_for_one, name: GateFixture.Supervisor)
        def health_check, do: #{if healthy?, do: ":ok", else: "{:error, :not_ready}"}
      end
      """)

    :code.purge(module)
    :code.delete(module)

    spec =
      {:application, :gate_fixture,
       [
         vsn: String.to_charlist(version),
         modules: [module],
         applications: [:kernel, :stdlib, :elixir, :nerves_gate_sdk],
         mod: {module, []},
         env: [
           nerves_gate_sdk_requirement: "~> 0.2.0-dev",
           nerves_gate_health_check: {module, :health_check, []}
         ]
       ]}

    root = "gate_fixture-#{version}"

    {:ok, {_, bytes}} =
      :zip.create(
        ~c"fixture.ez",
        [
          {String.to_charlist("#{root}/ebin/gate_fixture.app"),
           IO.iodata_to_binary(:io_lib.format(~c"~tp.~n", [spec]))},
          {String.to_charlist("#{root}/ebin/#{module}.beam"), beam}
        ],
        [:memory]
      )

    path = "/tmp/#{root}.ez"
    :ok = Scenarios.Device.rpc(vm, File, :write, [path, bytes], 30_000)
    path
  end

  defp apps(vm, :list, []) do
    {:ok, plugins} = Scenarios.Device.rpc(vm, NervesGate.Plugins, :list, [], 200_000)
    {:ok, Enum.reject(plugins, & &1.bundled?)}
  end

  defp apps(vm, function, args),
    do: Scenarios.Device.rpc(vm, NervesGate.Plugins, function, args, 200_000)

  defp await(predicate, attempts \\ 30)
  defp await(_, 0), do: flunk("Expected application storage state was not reached")

  defp await(predicate, attempts) do
    unless predicate.() do
      Process.sleep(100)
      await(predicate, attempts - 1)
    end
  end
end
