defmodule NervesGate.Scenarios.Hotplug do
  @moduledoc false
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def spec, do: %{:name => "LAN1 NIC removal and replacement recover without losing management"}

  def run(%{device: vm}) do
    try do
      NervesGate.TestQemu.remove_lan1(vm)

      Qemu.await(vm, "LAN1 device removed", fn status ->
        not Enum.any?(status.connections.ports, &match?(%{name: "eth0", present: true}, &1))
      end)
    after
      NervesGate.TestQemu.insert_lan1(vm)
    end

    Qemu.await(vm, "LAN1 device returned with address", &addressed?/1)
  end
end
