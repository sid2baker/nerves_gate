defmodule Scenarios.Cases.FirmwareUpgrade do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device

  def spec,
    do: %{
      name: "real SSH/fwup upgrades A → B → A preserve SSH access and saved settings",
      fresh_disk: true,
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    assert Scenarios.Device.status(vm).system.target == "x86_64"
    # Fresh disks boot the written image from slot A.
    assert slot?(vm, "a")
    {key, line, fingerprint} = ssh_key()
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.SSH, :add_key, [line])
    saved = save(vm, settings("eth0"))

    # Same disk and VM: fwup selects the next slot and its callback reboots.
    for slot <- ["b", "a"] do
      await_ssh(vm)
      assert {:ok, connection} = ssh_public_key(vm, key)

      try do
        assert :ok = Workbench.SSH.upload_firmware(connection, vm.firmware)
      after
        :ssh.close(connection)
      end

      restored =
        Scenarios.Device.await(
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
