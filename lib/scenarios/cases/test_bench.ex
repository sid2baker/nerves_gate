defmodule Scenarios.Cases.TestBench do
  @moduledoc false

  import ExUnit.Assertions

  alias Simulator.Faults, as: Faults

  alias Scenarios.Runner, as: Runner

  alias Workbench.TailnetAuth

  alias Scenarios.Qemu, as: Qemu

  # Holding every device proves that a run excludes other runs and manual control.
  def spec,
    do: %{
      :name => "bench ownership, reversible manual faults and cleanup preserve device settings",
      :devices => :all,
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm, devices: devices}) do
    assert_configuration(vm)
    assert_tailnet_tools()
    assert {:error, _} = Runner.stop_session(System.get_env("WORKBENCH_SESSION_ID"))
    assert_shutdown_admission()

    for id <- Map.keys(devices) do
      assert Runner.snapshot().devices[id].owner == Runner.snapshot().devices[vm.id].owner
      assert {:error, _} = Runner.run(id, "firewall")
      assert {:error, _} = Runner.install(id, "/tmp/not-read-while-device-is-reserved.ez")
      assert {:error, _} = Runner.mode(id, "manual")
      assert {:error, _} = Runner.mode(id, "scenarios")
      assert {:error, _} = Runner.manual(id, "lan1_down")
    end

    assert {:error, _} = Runner.run("unknown_device", "firewall")
    assert {:error, _} = Runner.configure({:put, "gateway_z", "lan1"})
    assert Runner.snapshot().lifecycle.status == :ready
    for action <- ~w(start stop reset), do: assert({:error, _} = Runner.lifecycle(action))
    before = Scenarios.Device.status(vm)
    assert Enum.map(before.connections.ports, & &1.name) |> Enum.sort() == ["eth0", "eth1"]
    assert Scenarios.Qemu.topology(vm) == Simulator.Network.baseline()
    assert Simulator.observe(vm).ready
    assert node(vm.owner) == node()
    {:monitors, monitors} = Process.info(Process.whereis(Runner), :monitors)
    assert {:process, Process.whereis(Simulator)} in monitors
    config = Qemu.network(vm)

    for patch <- [
          nil,
          %{management: false},
          %{cables: nil},
          %{cables: %{lan1: "false"}},
          %{cables: %{eth2: false}},
          %{internet: :unknown},
          %{uplink: %{loss: 50}},
          %{uplink: %{delay_ms: -1}},
          %{uplink: %{delay_ms: 5001}},
          %{uplink: %{delay_ms: 1.5}}
        ] do
      assert {:error, :invalid_network} = Qemu.network(vm, patch)
      assert Qemu.network(vm) == config
    end

    owner = self()
    report = Process.get(:qemu_fault)
    topology = Process.get(:qemu_topology)

    # Exercise the same long-lived manual driver on this runner's owned device.
    # The runner retains scenario ownership; no second runner or VM is created.
    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          Process.put(:qemu_fault, report)
          Process.put(:qemu_topology, topology)
          Faults.execute(owner, vm)
        end,
        [:link, :monitor]
      )

    try do
      assert_receive {:manual_ready, ^pid}, 5_000
      assert {:error, _} = Runner.mode(vm.id, "scenarios")
      faults(pid, vm)
      action(pid, "clear")
      recovered(vm, before)
      assert device(vm).faults == %{}

      # Release must clean up too, even when the browser did not press Clear.
      faults(pid, vm)
    after
      send(pid, {:manual_action, "release"})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
    end

    recovered(vm, before)
    assert device(vm).faults == %{}
    events = Runner.snapshot().events
    assert Enum.count_until(events, 101) <= 100
    ids = Enum.map(events, & &1.id)
    assert ids == Enum.sort(Enum.uniq(ids))
  end

  @doc false

  def assert_tailnet_tools do
    refute Enum.any?(Scenarios.select("all"), & &1.opt_in)

    assert [%{id: "tailscale_auth", opt_in: true, all: true}] =
             Scenarios.select("tailscale_auth")

    assert [] = Scenarios.select("unknown")

    # Use a non-secret fixture: this contract never requests a real CI key.
    previous =
      Map.new(~w(TAILSCALED_TEST_AUTH_KEY TS_OAUTH_CLIENT_ID), &{&1, System.get_env(&1)})

    try do
      System.put_env("TAILSCALED_TEST_AUTH_KEY", "local-test-key")
      assert TailnetAuth.auth_key() == {:ok, "local-test-key"}
      System.put_env("TAILSCALED_TEST_AUTH_KEY", "")
      assert {:error, _} = TailnetAuth.auth_key()
      for name <- Map.keys(previous), do: System.delete_env(name)
      assert TailnetAuth.auth_key() == {:error, "TS_OAUTH_CLIENT_ID is not set"}
    after
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end
  end

  defp assert_shutdown_admission do
    state = %{session_stopping: true, view: %{lifecycle: %{status: :stopping}}}
    assert {:reply, view, ^state} = Runner.handle_call(:snapshot, nil, state)
    assert view == state.view

    for command <- [
          {:run, "gateway_a", "all"},
          {:lifecycle, "start"},
          {:configure, :invalid},
          {:mode, "gateway_a", "manual"},
          {:manual, "gateway_a", "clear"}
        ] do
      assert {:reply, {:error, _}, ^state} = Runner.handle_call(command, nil, state)
    end
  end

  # Exercise configuration persistence without starting another simulator or VM.
  @doc false

  def assert_configuration(vm) do
    path = Path.join(vm.dir, "configuration.exs")
    dir = Path.join(vm.dir, "configuration")
    raw = %{firmware: vm.firmware, devices: %{first: %{provision: %{ssh_keys: []}}}}
    File.write!(path, inspect(raw))
    trap_exit = Process.flag(:trap_exit, true)

    try do
      {:ok, state} = Simulator.init(Simulator.config(path, dir))

      {:reply, :ok, state} =
        Simulator.handle_call({:configure, {:put, "second", "lan2"}}, nil, state)

      assert Simulator.config(path, dir).devices.second.network.internet == :lan2

      # New device IDs need explicit network preparation; no loopback aliases.
      assert Enum.map(state.view.devices, & &1.node) == [nil, nil]

      preserved = %{state | prepared: true}
      reject_configuration(preserved, {:put, "third", "lan1"})
      reject_configuration(preserved, {:delete, "second"})

      {:reply, :ok, _} =
        Simulator.handle_call({:configure, {:put, "first", "lan2"}}, nil, preserved)

      assert Simulator.config(path, dir).devices.first.provision == %{ssh_keys: []}
      assert Simulator.config(path, dir).devices.first.network.internet == :lan2

      for change <- [{:put, "bad-name", "lan1"}, {:put, "third", "off"}, {:delete, "unknown"}],
          do: reject_configuration(state, change)

      reject_configuration(put_in(state.view.status, :ready), {:put, "third", "lan1"})
      reject_configuration(put_in(state.view.reset_required, true), {:put, "third", "lan1"})
      {:reply, :ok, state} = Simulator.handle_call({:configure, {:delete, "second"}}, nil, state)
      reject_configuration(state, {:delete, "first"})
      assert Map.keys(Simulator.config(path, dir).devices) == [:first]
    after
      Process.flag(:trap_exit, trap_exit)
      File.rm!(path)
      File.rm(path <> ".tmp")
    end
  end

  defp reject_configuration(state, change) do
    before = File.read!(state.config.path)
    assert {:reply, {:error, _}, ^state} = Simulator.handle_call({:configure, change}, nil, state)
    assert File.read!(state.config.path) == before
  end

  defp faults(pid, vm) do
    action(pid, "lan1_down")
    action(pid, "connect_lan2")
    assert Scenarios.Qemu.topology(vm) == %{lan1: :plugin, lan2: :internet}
    assert device(vm).faults["lan1"]

    for action <- ~w(lan1_down lan2_down latency_on latency_on internet_loss internet_down),
        do: action(pid, action)

    Scenarios.Device.await(vm, "manual cables are disconnected", fn status ->
      Enum.all?(status.connections.ports, &(!&1.link))
    end)

    action(pid, "pause")
    assert Scenarios.Device.status(vm) == nil
    faults = device(vm).faults
    assert Enum.sort(Map.keys(faults)) == ~w(internet lan1 lan2 latency vm)
    assert faults["internet"] == "Internet outage"
  end

  defp device(vm), do: Runner.snapshot().devices[vm.id]

  defp action(pid, action) do
    send(pid, {:manual_action, action})
    assert_receive {:manual_done, ^pid, ^action}, 10_000
  end

  defp recovered(vm, before) do
    status =
      Scenarios.Device.await(vm, "manual cleanup restores management and both links", fn status ->
        Enum.all?(status.connections.ports, & &1.link) and
          status.remote.auth_state == before.remote.auth_state and
          status.remote.ipv4 == before.remote.ipv4
      end)

    assert Scenarios.Qemu.topology(vm) == Simulator.Network.baseline()
    assert device(vm).topology == Simulator.Network.baseline()
    assert status.network.desired == before.network.desired
    assert status.remote.auth_state == before.remote.auth_state
    assert status.remote.ipv4 == before.remote.ipv4
  end
end
