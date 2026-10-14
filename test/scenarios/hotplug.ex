defmodule NervesGate.Scenarios.Hotplug do
  @moduledoc false
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def name, do: "WAN NIC removal and replacement recover without losing management"

  def run(vm) do
    try do
      Qemu.unplug_wan(vm)

      Qemu.await(vm, "WAN device removed", fn status ->
        not Enum.any?(status.connections.ports, &match?(%{name: "eth0", present: true}, &1))
      end)
    after
      Qemu.plug_wan(vm)
    end

    Qemu.await(vm, "WAN device returned with address", &addressed?/1)
  end
end
