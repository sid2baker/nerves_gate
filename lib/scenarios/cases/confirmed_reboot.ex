defmodule Scenarios.Cases.ConfirmedReboot do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device
  alias Scenarios.Qemu, as: Qemu

  def spec,
    do: %{
      :name => "confirmed settings survive a VM reset",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    settings = save(vm, settings("eth0"))

    Qemu.reboot(vm)

    restored =
      Scenarios.Device.await(vm, "saved configuration and DHCP restored", fn status ->
        status.network.setup_completed && status.network.desired == settings && addressed?(status)
      end)

    assert restored.network.pending == nil
  end
end
