defmodule NervesGate.Scenarios.TestBench do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.{DevSession, ManualFaults, QemuTests, Simulator, TailnetAuth}
  alias NervesGate.TestQemu, as: Qemu

  # Holding every device proves that a run excludes other runs and manual control.
  def spec,
    do: %{
      :name => "bench ownership, reversible manual faults and cleanup preserve device settings",
      :devices => :all
    }

  def run(%{device: vm, devices: devices}) do
    assert_configuration(vm)
    assert_session_tools(vm)
    assert_tailnet_tools()
    assert {:error, _} = QemuTests.stop_session(System.get_env("QEMU_SESSION_ID"))
    assert_shutdown_admission()

    for id <- Map.keys(devices) do
      assert QemuTests.snapshot().devices[id].owner == QemuTests.snapshot().devices[vm.id].owner
      assert {:error, _} = QemuTests.run(id, "firewall")
      assert {:error, _} = QemuTests.install(id, "/tmp/not-read-while-device-is-reserved.ez")
      assert {:error, _} = QemuTests.mode(id, "manual")
      assert {:error, _} = QemuTests.mode(id, "scenarios")
      assert {:error, _} = QemuTests.manual(id, "lan1_down")
    end

    assert {:error, _} = QemuTests.run("unknown_device", "firewall")
    assert {:error, _} = QemuTests.configure({:put, "gateway_z", "lan1"})
    assert QemuTests.snapshot().lifecycle.status == :ready
    for action <- ~w(start stop reset), do: assert({:error, _} = QemuTests.lifecycle(action))
    before = Qemu.status(vm)
    assert Enum.map(before.connections.ports, & &1.name) |> Enum.sort() == ["eth0", "eth1"]
    assert NervesGate.TestQemu.topology(vm) == NervesGate.Simulator.Network.baseline()
    assert NervesGate.Simulator.observe(vm).ready
    simulator = Application.fetch_env!(:nerves_gate, :simulator_node)
    assert node(vm.owner) == simulator
    refute node(vm.owner) == node()
    {:monitors, monitors} = Process.info(Process.whereis(QemuTests), :monitors)
    assert {:process, {NervesGate.Simulator, simulator}} in monitors
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

    NervesGate.Scenarios.ProjectionStream.assert_bench_controls(vm)
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
          ManualFaults.execute(owner, vm)
        end,
        [:link, :monitor]
      )

    try do
      assert_receive {:manual_ready, ^pid}, 5_000
      assert {:error, _} = QemuTests.mode(vm.id, "scenarios")
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
    events = QemuTests.snapshot().events
    assert Enum.count_until(events, 101) <= 100
    ids = Enum.map(events, & &1.id)
    assert ids == Enum.sort(Enum.uniq(ids))
  end

  @doc false
  def assert_session_tools(vm) do
    dir = Path.join(vm.dir, "session-tooling")
    File.mkdir_p!(dir)
    id = DevSession.prepare(dir, 4_321)
    # Metadata and a leftover socket path must never be mistaken for a live lock.
    File.write!(Path.join(dir, "http.sock"), "stale")
    assert %{status: :stopped} = DevSession.status(dir)
    assert :ok = DevSession.stop(dir)
    lock = Path.join(dir, "session.lock")

    port =
      Port.open({:spawn_executable, System.find_executable("flock")}, [
        :binary,
        :exit_status,
        args: ["--nonblock", "--no-fork", lock, System.find_executable("cat")]
      ])

    try do
      Port.command(port, "locked\n")
      assert_receive {^port, {:data, "locked\n"}}, 5_000
      assert DevSession.locked?(dir)
      assert %{status: :starting, id: ^id, url: "http://localhost:4321"} = DevSession.status(dir)
      DevSession.phase(dir, :running)
      assert %{status: :unresponsive} = info = DevSession.status(dir)
      refute DevSession.describe(info) =~ id
      assert {:error, _} = DevSession.stop(dir)
      assert DevSession.locked?(dir)
      metadata = Path.join(dir, "session.json")
      saved = File.read!(metadata)
      File.write!(metadata, "not JSON")
      assert %{status: :unresponsive, id: nil} = DevSession.status(dir)
      assert {:error, _} = DevSession.stop(dir)
      assert DevSession.locked?(dir)
      File.write!(metadata, saved)
      DevSession.phase(dir, :stopping)
      assert %{status: :stopping} = DevSession.status(dir)
      task = Task.async(fn -> DevSession.stop(dir) end)
      assert Task.yield(task, 100) == nil
      Port.close(port)
      assert Task.await(task, 5_000) == :ok
      assert File.exists?(lock)
      assert %{status: :stopped} = DevSession.status(dir)
      assert_response_handoff(dir)
    after
      if Port.info(port), do: Port.close(port)
      File.rm_rf!(dir)
    end
  end

  @doc false
  def assert_tailnet_tools do
    refute Enum.any?(QemuTests.scenarios("all"), & &1.opt_in)

    assert [%{id: "tailscale_auth", opt_in: true, all: true}] =
             QemuTests.scenarios("tailscale_auth")

    assert [] = QemuTests.scenarios("unknown")

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
    assert {:reply, view, ^state} = QemuTests.handle_call(:snapshot, nil, state)
    assert view == state.view

    for command <- [
          {:run, "gateway_a", "all"},
          {:lifecycle, "start"},
          {:configure, :invalid},
          {:mode, "gateway_a", "manual"},
          {:manual, "gateway_a", "clear"}
        ] do
      assert {:reply, {:error, _}, ^state} = QemuTests.handle_call(command, nil, state)
    end
  end

  defp assert_response_handoff(dir) do
    request =
      spawn(fn ->
        receive do
          :done -> :ok
        after
          5_000 -> :ok
        end
      end)

    task = Task.async(fn -> DevSession.await_stop(dir) end)

    try do
      send(task.pid, {:stop_session, request})
      assert Task.yield(task, 100) == nil
      send(request, :done)
      assert Task.await(task, 5_000) == :stopped
    after
      send(request, :done)
      Task.shutdown(task, :brutal_kill)
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

      assert Enum.map(state.view.devices, & &1.node) ==
               [:"nerves_gate@127.0.0.2", :"nerves_gate@127.0.0.3"]

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
    assert NervesGate.TestQemu.topology(vm) == %{lan1: :equipment, lan2: :internet}
    assert device(vm).faults["lan1"]
    NervesGate.Scenarios.ProjectionStream.assert_bench_controls(vm)

    for action <- ~w(lan1_down lan2_down latency_on latency_on internet_loss internet_down),
        do: action(pid, action)

    Qemu.await(vm, "manual cables are disconnected", fn status ->
      Enum.all?(status.connections.ports, &(!&1.link))
    end)

    action(pid, "pause")
    assert Qemu.status(vm) == nil
    faults = device(vm).faults
    assert Enum.sort(Map.keys(faults)) == ~w(internet lan1 lan2 latency vm)
    assert faults["internet"] == "Internet outage"
  end

  defp device(vm), do: QemuTests.snapshot().devices[vm.id]

  defp action(pid, action) do
    send(pid, {:manual_action, action})
    assert_receive {:manual_done, ^pid, ^action}, 10_000
  end

  defp recovered(vm, before) do
    status =
      Qemu.await(vm, "manual cleanup restores management and both links", fn status ->
        Enum.all?(status.connections.ports, & &1.link) and
          status.remote_access.auth_state == before.remote_access.auth_state and
          status.remote_access.ipv4 == before.remote_access.ipv4
      end)

    assert NervesGate.TestQemu.topology(vm) == NervesGate.Simulator.Network.baseline()
    assert device(vm).topology == NervesGate.Simulator.Network.baseline()
    assert status.network.desired == before.network.desired
    assert status.remote_access.auth_state == before.remote_access.auth_state
    assert status.remote_access.ipv4 == before.remote_access.ipv4
  end
end
