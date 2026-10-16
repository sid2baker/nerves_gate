defmodule NervesGate.Scenarios.ConfirmedReboot do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def spec, do: %{:name => "confirmed settings survive a VM reset"}

  def run(%{device: vm}) do
    settings = save(vm, settings("eth0"))

    Qemu.reboot(vm)

    restored =
      Qemu.await(vm, "saved configuration and DHCP restored", fn status ->
        status.network.setup_completed && status.network.desired == settings && addressed?(status)
      end)

    assert restored.network.pending == nil
  end
end
