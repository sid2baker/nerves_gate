defmodule Scenarios.Cases.SystemArtifact do
  @moduledoc false
  import ExUnit.Assertions

  @system Path.expand("../../../systems/nerves_system_ec100_qemu", __DIR__)

  def spec,
    do: %{
      name: "QEMU runs the versioned system and boot contract",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    assert Scenarios.Device.status(vm).system.node == vm.node
    version = File.read!(Path.join(@system, "VERSION")) |> String.trim()

    assert {:ok, os_release} =
             Scenarios.Device.rpc(vm, File, :read, ["/usr/lib/os-release"], 5_000)

    assert "NERVES_SYSTEM_VERSION=#{version}" in String.split(os_release, "\n")

    assert Scenarios.Device.rpc(vm, Nerves.Runtime.KV, :get_active, ["nerves_fw_platform"], 5_000) ==
             "x86_64"

    assert_boot_contract(vm)
    assert_restart_policy(vm)
    Scenarios.Device.await_firmware_validated(vm)
  end

  defp assert_boot_contract(vm) do
    assert Scenarios.Device.rpc(vm, Application, :fetch_env!, [:nerves_runtime, :init_module]) ==
             NervesGate.Recovery.DataInit

    assert Scenarios.Device.rpc(vm, Application, :fetch_env!, [
             :ssh_subsystem_fwup,
             :precheck_callback
           ]) ==
             {NervesGate.Recovery.EC100, :firmware_precheck, []}

    serial = Scenarios.Device.rpc(vm, Nerves.Runtime, :serial_number, [])
    # :inet.gethostname/0 drops everything from the first dot of the QEMU serial.
    hostname = Scenarios.Device.rpc(vm, File, :read!, ["/proc/sys/kernel/hostname"])
    assert String.trim(hostname) == serial
    # USB recovery hashes the full serial, so QEMU advertises it as the DHCP hostname.
    usb0 = %{type: VintageNetDirect, vintage_net_direct: %{hostname: serial}}
    defaults = Scenarios.Device.rpc(vm, Application, :fetch_env!, [:vintage_net, :config])
    assert {"usb0", usb0} in defaults
    assert Scenarios.Device.rpc(vm, VintageNet, :get_configuration, ["usb0"]) == usb0

    assert Scenarios.Device.rpc(vm, File, :read!, ["/sys/class/net/usb0/address"]) ==
             "52:54:00:12:34:59\n"

    refute Scenarios.Device.rpc(vm, File, :exists?, ["/sys/class/net/eth3"])

    for interface <- ["eth0", "eth1", "eth2"],
        do: assert(Scenarios.Device.rpc(vm, File, :exists?, ["/sys/class/net/#{interface}"]))

    assert Scenarios.Device.rpc(vm, Application, :fetch_env, [:nerves_gate, :backend_node]) ==
             :error

    assert {:ok, _mount} = Scenarios.Device.rpc(vm, NervesGate.Recovery.DataInit, :check_data, [])
    assert Scenarios.Device.rpc(vm, NervesGate.Board, :get, [:recovery_adapter]) == nil
    refute Scenarios.Device.rpc(vm, Code, :ensure_loaded?, [Workbench.Application])
  end

  defp assert_restart_policy(vm) do
    root = Scenarios.Device.rpc(vm, :code, :root_dir, []) |> to_string()
    version = Scenarios.Device.rpc(vm, Application, :spec, [:nerves_gate, :vsn]) |> to_string()
    path = Path.join([root, "releases", version, "nerves_gate.rel"]) |> String.to_charlist()
    assert {:ok, [{:release, _, _, apps}]} = Scenarios.Device.rpc(vm, :file, :consult, [path])
    assert {:nerves_gate, _, :transient} = List.keyfind(apps, :nerves_gate, 0)

    for dependency <- [:vintage_net, :tailscaled_ex, :alarmist] do
      assert {^dependency, _, :temporary} = List.keyfind(apps, dependency, 0)
    end
  end
end
