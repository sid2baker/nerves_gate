defmodule NervesGate.Scenarios.TestBench do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.{ManualFaults, QemuTests}
  alias NervesGate.TestQemu, as: Qemu

  def name, do: "bench ownership, reversible manual faults and cleanup preserve device settings"

  def run(vm) do
    assert {:error, _} = QemuTests.run("firewall")
    assert {:error, _} = QemuTests.mode("manual")
    assert {:error, _} = QemuTests.manual("lan1_down")
    before = Qemu.status(vm)
    assert Enum.map(before.connections.ports, & &1.name) |> Enum.sort() == ["eth0", "eth1"]
    assert Qemu.topology() == NervesGate.TestNetwork.baseline()
    assert NervesGate.TestNetwork.snapshot().ready
    relay = Process.whereis(NervesGate.TestNetwork)
    assert Process.alive?(relay)
    {:monitors, monitors} = Process.info(Process.whereis(QemuTests), :monitors)
    assert {:process, relay} in monitors
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

    NervesGate.Scenarios.ProjectionStream.assert_bench_controls()
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
      assert {:error, _} = QemuTests.mode("scenarios")
      faults(pid, vm)
      action(pid, "clear")
      recovered(vm, before)
      assert QemuTests.snapshot().faults == %{}

      # Release must clean up too, even when the browser did not press Clear.
      faults(pid, vm)
    after
      send(pid, {:manual_action, "release"})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
    end

    recovered(vm, before)
    assert QemuTests.snapshot().faults == %{}
    events = QemuTests.snapshot().events
    assert Enum.count_until(events, 101) <= 100
    ids = Enum.map(events, & &1.id)
    assert ids == Enum.sort(Enum.uniq(ids))
  end

  defp faults(pid, vm) do
    action(pid, "lan1_down")
    action(pid, "connect_lan2")
    assert Qemu.topology() == %{lan1: :equipment, lan2: :internet}
    assert QemuTests.snapshot().faults["lan1"]
    NervesGate.Scenarios.ProjectionStream.assert_bench_controls()

    for action <- ~w(lan1_down lan2_down latency_on latency_on internet_loss internet_down),
        do: action(pid, action)

    Qemu.await(vm, "manual cables are disconnected", fn status ->
      Enum.all?(status.connections.ports, &(!&1.link))
    end)

    action(pid, "pause")
    assert Qemu.status(vm) == nil
    faults = QemuTests.snapshot().faults
    assert Enum.sort(Map.keys(faults)) == ~w(internet lan1 lan2 latency vm)
    assert faults["internet"] == "Internet outage"
  end

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

    assert Qemu.topology() == NervesGate.TestNetwork.baseline()
    assert QemuTests.snapshot().topology == NervesGate.TestNetwork.baseline()
    assert status.network.desired == before.network.desired
    assert status.remote_access.auth_state == before.remote_access.auth_state
    assert status.remote_access.ipv4 == before.remote_access.ipv4
  end
end
