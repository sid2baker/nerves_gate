defmodule Scenarios.Cases.Storage do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device
  alias Scenarios.Qemu, as: Qemu

  def spec,
    do: %{
      name: "disk write errors are reported instead of confirming unsaved settings",
      fresh_disk: true,
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    save(vm, settings("eth0"))
    trial = propose(vm, settings("eth1"))

    try do
      Qemu.fail_disk_writes(vm)

      assert {:error, %{code: "save_failed"}} =
               Scenarios.Device.rpc(vm, NervesGate.Network, :confirm, [trial])

      assert Qemu.failed_disk_writes(vm) > 0

      restored =
        Scenarios.Device.await(vm, "failed save did not confirm the new settings", fn status ->
          status.network.pending == nil && not status.network.recovering &&
            status.network.desired == settings("eth0")
        end)

      assert restored.device.available
      assert restored.network.error.code == "save_failed"
    after
      Qemu.restore_disk_writes(vm)
    end
  end
end
