defmodule Simulator.Scenarios.SystemArtifact do
  @moduledoc false
  import ExUnit.Assertions
  alias Simulator.TestQemu, as: Qemu

  @system Path.expand("../../../systems/nerves_system_ec100_qemu", __DIR__)

  def spec, do: %{name: "QEMU runs the versioned system and boot contract"}

  def run(%{device: vm}) do
    assert Qemu.status(vm).system.node == vm.node
    version = File.read!(Path.join(@system, "VERSION")) |> String.trim()
    assert {:ok, os_release} = :erpc.call(vm.node, File, :read, ["/usr/lib/os-release"], 5_000)
    assert "NERVES_SYSTEM_VERSION=#{version}" in String.split(os_release, "\n")

    assert :erpc.call(vm.node, Nerves.Runtime.KV, :get_active, ["nerves_fw_platform"], 5_000) ==
             "x86_64"

    assert_boot_contract(vm)
    assert_restart_policy(vm)
    Simulator.ScenarioHelpers.await_firmware_validated(vm)
  end

  defp assert_boot_contract(vm) do
    assert :erpc.call(vm.node, Application, :fetch_env!, [:nerves_runtime, :init_module]) ==
             NervesGate.Recovery.DataInit

    assert :erpc.call(vm.node, Application, :fetch_env!, [:ssh_subsystem_fwup, :precheck_callback]) ==
             {NervesGate.Recovery.EC100, :firmware_precheck, []}

    serial = :erpc.call(vm.node, Nerves.Runtime, :serial_number, [])
    assert {:ok, hostname} = :erpc.call(vm.node, :inet, :gethostname, [])
    assert to_string(hostname) == serial
    defaults = :erpc.call(vm.node, Application, :fetch_env!, [:vintage_net, :config])
    assert {"usb0", %{type: VintageNetDirect}} in defaults

    assert :erpc.call(vm.node, VintageNet, :get_configuration, ["usb0"]) ==
             %{type: VintageNetDirect, vintage_net_direct: %{}}

    assert :erpc.call(vm.node, File, :read!, ["/sys/class/net/usb0/address"]) ==
             "52:54:00:12:34:59\n"

    refute :erpc.call(vm.node, File, :exists?, ["/sys/class/net/eth3"])

    for interface <- ["eth0", "eth1", "eth2"],
        do: assert(:erpc.call(vm.node, File, :exists?, ["/sys/class/net/#{interface}"]))

    assert :erpc.call(vm.node, Application, :fetch_env!, [:nerves_gate, :backend_node]) == :local
    assert {:ok, _mount} = :erpc.call(vm.node, NervesGate.Recovery.DataInit, :check_data, [])
    assert :erpc.call(vm.node, NervesGate.Board, :get, [:recovery_adapter]) == nil
    refute :erpc.call(vm.node, Code, :ensure_loaded?, [Dev.GatewayInit])
  end

  defp assert_restart_policy(vm) do
    root = :erpc.call(vm.node, :code, :root_dir, []) |> to_string()
    version = :erpc.call(vm.node, Application, :spec, [:nerves_gate, :vsn]) |> to_string()
    path = Path.join([root, "releases", version, "nerves_gate.rel"]) |> String.to_charlist()
    assert {:ok, [{:release, _, _, apps}]} = :erpc.call(vm.node, :file, :consult, [path])
    assert {:nerves_gate, _, :transient} = List.keyfind(apps, :nerves_gate, 0)

    for dependency <- [:vintage_net, :tailscaled_ex, :alarmist] do
      assert {^dependency, _, :temporary} = List.keyfind(apps, dependency, 0)
    end
  end
end
