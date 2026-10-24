defmodule Scenarios.Cases.TrialReboot do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device
  alias Scenarios.Qemu, as: Qemu

  def spec,
    do: %{
      :name => "reset during an unconfirmed trial restores only confirmed settings",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    saved = save(vm, settings("eth0"))
    propose(vm, settings("eth1"))
    Qemu.reboot(vm)

    restored =
      Scenarios.Device.await(vm, "unconfirmed settings discarded after reset", fn status ->
        status.network.desired == saved && status.network.pending == nil &&
          not status.network.recovering && addressed?(status)
      end)

    assert restored.network.setup_completed
  end
end
