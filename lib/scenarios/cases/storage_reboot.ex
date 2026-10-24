defmodule Scenarios.Cases.StorageReboot do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device
  alias Scenarios.Qemu, as: Qemu

  def spec,
    do: %{
      name: "reboot after failed persistence never accepts the failed update",
      fresh_disk: true,
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    saved = settings("eth0")
    rejected = settings("eth1")
    save(vm, saved)
    trial = propose(vm, rejected)

    try do
      Qemu.fail_disk_writes(vm)

      assert {:error, %{code: "save_failed"}} =
               Scenarios.Device.rpc(vm, NervesGate.Network, :confirm, [trial])

      assert Qemu.failed_disk_writes(vm) > 0

      Scenarios.Device.await(vm, "failed confirmation finished", fn status ->
        status.network.pending == nil && not status.network.recovering
      end)
    after
      Qemu.restore_disk_writes(vm)
    end

    restarted = Qemu.power_cycle(vm)

    status =
      Scenarios.Device.await(restarted, "network state loaded after disk failure", fn status ->
        status.network.available && not status.network.recovering
      end)

    assert status.network.pending == nil
    refute status.network.desired == rejected

    if status.network.setup_completed do
      assert status.network.desired == saved
    else
      assert status.network.desired == %{"mode" => "unconfigured"}
      assert status.network.error != nil
    end
  end
end
