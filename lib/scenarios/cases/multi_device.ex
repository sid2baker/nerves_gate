defmodule Scenarios.Cases.MultiDevice do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device
  alias Simulator.SSH

  def spec,
    do: %{
      name: "independent devices: USB bootstrap, disks, faults and power",
      devices: :all,
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: first, devices: devices}) do
    assert map_size(devices) >= 2, "multi_device requires at least two configured devices"
    second = devices |> Map.delete(first.id) |> Enum.sort_by(&elem(&1, 0)) |> hd() |> elem(1)
    assert first.node != second.node
    assert first.address != second.address
    assert first.owner != second.owner
    assert first.dir != second.dir
    assert serial(first) != serial(second)

    for vm <- [first, second] do
      assert Simulator.observe(vm).ready

      assert {:ok, %{active: "b", next: "b"}} =
               Scenarios.Device.rpc(vm, Nerves.Runtime.FwupOps, :status, [])

      assert %{type: VintageNetDirect} =
               Scenarios.Device.rpc(vm, VintageNet, :get_configuration, ["usb0"])

      assert {:ok, connection} =
               SSH.connect(vm, vm.forwards.usb,
                 user: ~c"root",
                 password: ~c"nerves_gate",
                 auth_methods: ~c"password"
               )

      try do
        assert SSH.request(connection, "Node.self()") == vm.node
        assert SSH.request(connection, "NervesGate.System.info().target") == "x86_64"
      after
        :ssh.close(connection)
      end
    end

    original = Simulator.observe(first).config
    other = Simulator.observe(second).config
    boot = boot_id(second)
    first_boot = boot_id(first)
    other_settings = Scenarios.Device.status(second).network.desired
    {_key, line, fingerprint} = ssh_key()

    assert {:ok, connection} =
             SSH.connect(first, first.forwards.usb,
               user: ~c"root",
               password: ~c"nerves_gate",
               auth_methods: ~c"password"
             )

    try do
      assert :ok = SSH.provision(connection, %{ssh_keys: [line], network: settings("eth0")})
    after
      :ssh.close(connection)
    end

    try do
      assert not has_key?(second, fingerprint)
      assert :ok = Simulator.network(first, %{internet: :off, cables: %{lan1: false}})
      assert Simulator.observe(second).config == other
      assert Scenarios.Device.status(second).device.available

      Simulator.command(first, :pause)

      try do
        assert Scenarios.Device.status(second).device.available
        assert boot_id(second) == boot
        assert Simulator.observe(second).ready
      after
        Simulator.command(first, :resume)
      end

      # Replace only A's QEMU process, preserving its disk and selected faults.
      assert :ok = Simulator.command(first, :power_cycle)
      assert boot_id(first) != first_boot
      assert has_key?(first, fingerprint)
      assert Scenarios.Device.status(first).network.desired == settings("eth0")
      assert Scenarios.Device.status(second).network.desired == other_settings
      assert not has_key?(second, fingerprint)
      assert Simulator.observe(first).config.internet == :off
      assert Simulator.observe(second).config == other
      assert boot_id(second) == boot
    after
      # Unknown control outcomes block admission instead of retrying cleanup.
      assert :ok = Simulator.network(first, original)
      assert :ok = Scenarios.Device.rpc(first, NervesGate.SSH, :remove_key, [fingerprint])
    end
  end

  defp serial(vm), do: Scenarios.Device.rpc(vm, Nerves.Runtime, :serial_number, [])

  defp boot_id(vm),
    do: Scenarios.Device.rpc(vm, File, :read!, ["/proc/sys/kernel/random/boot_id"])

  defp has_key?(vm, fingerprint),
    do: Enum.any?(Scenarios.Device.status(vm).ssh.keys, &(&1.fingerprint == fingerprint))
end
