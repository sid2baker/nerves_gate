defmodule Simulator.Scenarios.FirmwareUpgrade do
  @moduledoc false
  import ExUnit.Assertions
  import Simulator.ScenarioHelpers
  alias Simulator.SSH
  alias Simulator.TestQemu, as: Qemu

  def spec,
    do: %{
      name: "real SSH/fwup upgrades B → A → B preserve SSH access and saved settings",
      fresh_disk: true
    }

  def run(%{device: vm}) do
    assert Qemu.status(vm).system.target == "x86_64"
    # Factory A → current B is part of simulator bootstrap, also on fresh disks.
    assert slot?(vm, "b")
    {key, line, fingerprint} = ssh_key()
    assert :ok = Qemu.call(vm, :ssh_add_key, [line])
    saved = save(vm, settings("eth0"))

    # Same disk and VM: fwup selects the next slot and its callback reboots.
    for slot <- ["a", "b"] do
      await_ssh(vm)
      assert {:ok, connection} = ssh_public_key(vm, key)

      try do
        assert :ok = SSH.upload(connection, vm.firmware)
      after
        :ssh.close(connection)
      end

      restored =
        Qemu.await(
          vm,
          "firmware booted from slot #{slot}",
          fn status ->
            slot?(vm, slot) && status.network.setup_completed && not status.network.recovering
          end,
          180_000
        )

      # fwup leaves the new slot unvalidated; only the booted application validates it.
      await_firmware_validated(vm)
      assert restored.network.desired == saved
      assert restored.network.pending == nil
      assert Enum.any?(restored.ssh.keys, &(&1.fingerprint == fingerprint))
    end

    await_ssh(vm)
    assert {:ok, connection} = ssh_public_key(vm, key)
    :ok = :ssh.close(connection)
  end

  defp slot?(vm, slot) do
    # Check the mounted root partition as well as next-boot metadata.
    match?(
      {:ok, %{active: ^slot, next: ^slot}},
      :rpc.call(vm.node, Nerves.Runtime.FwupOps, :status, [], 2000)
    )
  end
end
