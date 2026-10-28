defmodule Scenarios.ManagedPlugin do
  @moduledoc "Real SDK fixture plugins on reserved, disposable QEMU storage. Never a hardware/backend substitute."
  import ExUnit.Assertions
  alias Scenarios.Device

  def with_plugin(vm, fun, opts \\ []) do
    ports = Keyword.get(opts, :assigned_ports, [])
    prepare_storage(vm)
    directory = Path.join(System.tmp_dir!(), "gate-managed-#{nonce()}")
    guest = "/tmp/managed-fixture-#{nonce()}.ez"

    try do
      path = build!(directory, "1.0.0")
      :ok = Device.rpc(vm, File, :write, [guest, File.read!(path)])
      assert {:ok, _} = plugins(vm, :install, [guest])

      for port <- ports,
          do: assert(:ok == plugins(vm, :assign_port, [port, true, "managed_fixture", true]))

      assert :ok = plugins(vm, :start, [:managed_fixture])
      client = main(vm)
      fun.(client)
    after
      # Device.rpc prevents cleanup writes when a previous control result was lost.
      case plugins(vm, :list, []) do
        {:ok, entries} ->
          if Enum.any?(entries, &(&1.app == "managed_fixture")),
            do: assert(:ok == plugins(vm, :uninstall, [:managed_fixture]))

        error ->
          flunk("Fixture cleanup requires known plugin state: #{inspect(error)}")
      end

      for port <- ports,
          do: assert(:ok == plugins(vm, :assign_port, [port, false, nil, true]))

      Device.rpc(vm, File, :rm, [guest])
      File.rm_rf!(directory)
    end
  end

  def prepare_storage(%{fixture: {:qemu, handle}} = vm) do
    true = vm.node == handle.node
    Scenarios.Qemu.network_stats(handle)
    assert {:ok, plugins} = plugins(vm, :list, [])
    assert Enum.all?(plugins, & &1.bundled?)
    storage = Device.rpc(vm, NervesGate.Storage, :commissioning)
    assert storage.present
    assert storage.choice in [:pending, :use]

    if storage.choice == :pending do
      assert :ok = Device.rpc(vm, NervesGate.Storage, :setup, [:use, storage.card_id])
    end

    Device.await(vm, "disposable plugin storage and manager ready", fn _ ->
      match?({:ok, _}, Device.rpc(vm, NervesGate.Storage, :identity)) and idle?(vm)
    end)

    :ok
  end

  def prepare_storage(_),
    do: raise(ArgumentError, "Managed SDK fixtures require owned disposable QEMU")

  @doc "Wait until a booted device's plugin manager restored firmware plugins and is idle."
  def await_idle(vm), do: await_idle(vm, "firmware plugins discovered and manager idle")
  def await_idle(vm, phase), do: Device.await(vm, phase, fn _ -> idle?(vm) end)

  defp idle?(vm) do
    state = Device.rpc(vm, :sys, :get_state, [NervesGate.Plugins])
    state.restored? and state.job == nil and state.blocked == nil
  end

  def build!(directory, version, options \\ []) do
    project = Path.join(directory, "fixture-#{version}-#{nonce()}")
    File.mkdir_p!(Path.join(project, "lib"))

    env = [
      nerves_gate_sdk_requirement: "~> 0.2.0-dev",
      nerves_gate_hardware: [:ethernet],
      nerves_gate_health_check: {ManagedFixture.Application, :health_check, []},
      fixture_health: Keyword.get(options, :health, :ok),
      fixture_start: Keyword.get(options, :start, :ok),
      fixture_preload: Keyword.get(options, :preload, :ok)
    ]

    File.write!(Path.join(project, "mix.exs"), """
    defmodule ManagedFixture.MixProject do
      use Mix.Project
      def project, do: [app: :managed_fixture, version: #{inspect(version)}, elixir: "~> 1.20", deps: [{:nerves_gate_sdk, "~> 0.2.0-dev", path: #{inspect(Path.join(Workbench.root(), "sdk"))}}]]
      def application, do: [extra_applications: [:logger], mod: {ManagedFixture.Application, []}, env: #{inspect(env, limit: :infinity)}]
      def cli, do: [preferred_envs: ["nerves_gate.package": :prod]]
    end
    """)

    File.cp!(
      Path.join(Workbench.root(), "priv/scenarios/managed_fixture.ex"),
      Path.join(project, "lib/managed_fixture.ex")
    )

    Workbench.Plugins.package!(project)
  end

  def upload(vm, directory, version, options \\ []) do
    archive = build!(directory, version, options)
    guest = "/tmp/managed-fixture-#{nonce()}.ez"
    :ok = Device.rpc(vm, File, :write, [guest, File.read!(archive)])
    guest
  end

  def plugins(vm, function, args), do: Device.rpc(vm, NervesGate.Plugins, function, args, 200_000)
  def main(vm), do: Device.rpc(vm, Process, :whereis, [ManagedFixture.Main])

  def client(vm) do
    {:ok, pid} =
      Device.rpc(vm, DynamicSupervisor, :start_child, [
        ManagedFixture.Clients,
        {ManagedFixture.Client, []}
      ])

    pid
  end

  def call(vm, pid, module, function, args \\ []),
    do:
      Device.rpc(vm, GenServer, :call, [pid, {:invoke, module, function, args}, 190_000], 200_000)

  def stop_client(vm, pid),
    do: Device.rpc(vm, DynamicSupervisor, :terminate_child, [ManagedFixture.Clients, pid])

  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
