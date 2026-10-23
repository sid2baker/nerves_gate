defmodule Simulator.Scenarios.Apps do
  @moduledoc false
  import ExUnit.Assertions

  def spec do
    %{name: "SD application install, cold upgrade, rollback and removal", fresh_disk: true}
  end

  def run(%{device: vm}) do
    commission_storage(vm)
    install_generated_app(vm)

    # Card removal uses a disposable Linux mount inside the supervised guest. No
    # host mounts, arbitrary VMs, hardware adapters or physical cards are involved.
    mount = "/tmp/nerves-gate-apps"
    call(vm, File, :mkdir_p!, [mount])
    call(vm, Application, :put_env, [:nerves_gate, :apps_device, nil])
    call(vm, Application, :put_env, [:nerves_gate, :apps_mount, mount])
    assert {:ok, %{available?: false}} = call(vm, NervesGate.Storage, :status, [])
    assert {:error, :storage_unavailable} = call(vm, NervesGate.Apps, :install, ["/missing.ez"])
    {_, 0} = call(vm, System, :cmd, ["mount", ["-t", "tmpfs", "-o", "size=32m", "tmpfs", mount]])

    try do
      first = upload(vm, "1.0.0", true)
      second = upload(vm, "1.1.0", true)
      broken = upload(vm, "1.2.0", false)
      assert {:ok, %{app: :gate_fixture, version: "1.0.0"}} = apps(vm, :install, [first])
      assert [{:gate_fixture, "1.0.0", false}] == selection(vm)

      assert {:error, :applications_installed} =
               call(vm, NervesGate.Storage, :setup, [:format, nil, :erase_all_data])

      assert :ok = apps(vm, :start, [:gate_fixture])
      assert [{:gate_fixture, "1.0.0", true}] == selection(vm)
      assert {:ok, data} = call(vm, NervesGate.Storage, :data_dir, [:gate_fixture])
      assert :ok = call(vm, File, :write, [Path.join(data, "state"), "preserved"])

      assert :ok = apps(vm, :upgrade, [second])
      assert [{:gate_fixture, "1.1.0", true}] == selection(vm)
      assert {:error, {:rolled_back, _}} = apps(vm, :upgrade, [broken])
      assert [{:gate_fixture, "1.1.0", true}] == selection(vm)
      assert :ok = apps(vm, :rollback, [:gate_fixture])
      assert [{:gate_fixture, "1.0.0", true}] == selection(vm)
      assert :ok = apps(vm, :restart, [:gate_fixture])

      assert :ok =
               call(vm, Supervisor, :terminate_child, [NervesGate.Supervisor, NervesGate.Apps])

      assert {:ok, _} =
               call(vm, Supervisor, :restart_child, [NervesGate.Supervisor, NervesGate.Apps])

      await(fn -> selection(vm) == [{:gate_fixture, "1.0.0", true}] end)

      assert :ok = apps(vm, :stop, [:gate_fixture])
      assert [{:gate_fixture, "1.0.0", false}] == selection(vm)

      refute :gate_fixture in Enum.map(
               call(vm, Application, :loaded_applications, []),
               &elem(&1, 0)
             )

      assert :ok = apps(vm, :start, [:gate_fixture])
      assert :ok = apps(vm, :uninstall, [:gate_fixture])
      assert [] == selection(vm)
      assert "preserved" = call(vm, File, :read!, [Path.join(data, "state")])

      {_, 0} = call(vm, System, :cmd, ["umount", [mount]])
      assert {:ok, %{available?: false}} = call(vm, NervesGate.Storage, :status, [])

      assert {:error, :storage_unavailable} =
               call(vm, NervesGate.Storage, :data_dir, [:gate_fixture])
    after
      apps(vm, :uninstall, [:gate_fixture])
      call(vm, System, :cmd, ["umount", [mount]])
      call(vm, Application, :delete_env, [:nerves_gate, :apps_mount])
      call(vm, Application, :put_env, [:nerves_gate, :apps_device, "/dev/vdb"])

      for version <- ~w(1.0.0 1.1.0 1.2.0),
          do: call(vm, File, :rm, ["/tmp/gate_fixture-#{version}.ez"])
    end
  end

  defp install_generated_app(vm) do
    dir = Path.join(System.tmp_dir!(), "gate_app_#{System.unique_integer([:positive])}")

    try do
      app = Dev.Applications.new!(Path.join(dir, "generated_fixture"), true)
      package = Dev.Applications.package!(app.path)
      assert {:ok, _} = Simulator.Apps.install(vm, package)
      assert {:ok, entries} = apps(vm, :list, [])
      assert Enum.any?(entries, &(&1.app == "generated_fixture" and &1.running?))
      assert :ok = apps(vm, :uninstall, [:generated_fixture])
    after
      apps(vm, :uninstall, [:generated_fixture])
      File.rm_rf!(dir)
    end
  end

  defp commission_storage(vm) do
    storage = fn -> call(vm, NervesGate.Storage, :commissioning, []) end
    await(fn -> storage.().present end)
    assert storage.().choice == :pending
    assert {:error, :storage_unavailable} = call(vm, NervesGate.Storage, :root, [])

    assert :ok = call(vm, NervesGate.Storage, :setup, [:skip])

    assert :ok =
             call(vm, Supervisor, :terminate_child, [NervesGate.Supervisor, NervesGate.Storage])

    assert {:ok, _} =
             call(vm, Supervisor, :restart_child, [NervesGate.Supervisor, NervesGate.Storage])

    assert storage.().choice == :skip

    id = storage.().card_id
    assert {:error, :storage_card_changed} = call(vm, NervesGate.Storage, :setup, [:use, "stale"])

    assert {:error, :storage_confirmation_required} =
             call(vm, NervesGate.Storage, :setup, [:format, id])

    # The preformatted QEMU card still requires a commissioning choice.
    assert :ok = call(vm, NervesGate.Storage, :setup, [:use, id])
    await(fn -> storage.().ready end)
    assert {:ok, data} = call(vm, NervesGate.Storage, :data_dir, [:format_fixture])
    marker = Path.join(data, "preserve-or-erase")
    assert :ok = call(vm, File, :write, [marker, "preserved"])
    assert :ok = call(vm, NervesGate.Storage, :setup, [:skip])
    assert :ok = call(vm, NervesGate.Storage, :setup, [:use, storage.().card_id])
    await(fn -> storage.().ready end)
    assert "preserved" = call(vm, File, :read!, [marker])

    # Refuse the mounted firmware disk, without a platform/target switch.
    call(vm, Application, :put_env, [:nerves_gate, :apps_device, "/dev/vda"])

    try do
      await(fn -> storage.().card_id != id end)

      assert {:error, :storage_in_use} =
               call(vm, NervesGate.Storage, :setup, [:format, storage.().card_id, :erase_all_data])
    after
      call(vm, Application, :put_env, [:nerves_gate, :apps_device, "/dev/vdb"])
    end

    await(fn -> storage.().filesystem == "ext4" end)
    assert :ok = call(vm, NervesGate.Storage, :setup, [:skip])

    # Make the disposable card unprepared by clearing its ext magic. No host
    # block device is opened; setup must reject using this card without erasing.
    {result, _} =
      call(vm, Code, :eval_string, [
        """
        {:ok, fd} = :file.open(~c"/dev/vdb", [:read, :write, :binary, :raw])
        try do
          :file.pwrite(fd, 1080, <<0, 0>>)
        after
          :file.close(fd)
        end
        """
      ])

    assert result == :ok
    await(fn -> storage.().filesystem == "Unknown" end)

    assert {:error, :storage_filesystem} =
             call(vm, NervesGate.Storage, :setup, [:use, storage.().card_id])

    assert :ok =
             call(vm, NervesGate.Storage, :setup, [:format, storage.().card_id, :erase_all_data])

    await(fn -> storage.().operation == nil end, 1_300)
    assert storage.().error == nil
    assert storage.().ready
    refute call(vm, File, :exists?, [marker])
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
           nerves_gate_sdk_requirement: "~> 0.1.0",
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
    :ok = call(vm, File, :write, [path, bytes])
    path
  end

  defp apps(vm, function, args), do: call(vm, NervesGate.Apps, function, args)
  defp call(vm, module, function, args), do: :erpc.call(vm.node, module, function, args, 30_000)

  defp await(predicate, attempts \\ 30)
  defp await(_, 0), do: flunk("Expected application storage state was not reached")

  defp await(predicate, attempts) do
    unless predicate.() do
      Process.sleep(100)
      await(predicate, attempts - 1)
    end
  end
end
