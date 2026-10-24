defmodule Scenarios.Cases.Hotplug do
  @moduledoc false
  import Scenarios.Device
  alias Scenarios.Qemu, as: Qemu

  def spec,
    do: %{
      :name => "LAN1 NIC removal and replacement recover without losing management",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    for _ <- 1..3 do
      try do
        Qemu.remove_lan1(vm)

        Scenarios.Device.await(vm, "LAN1 device removed", fn status ->
          not Enum.any?(status.connections.ports, &match?(%{name: "eth0", present: true}, &1))
        end)
      after
        Qemu.insert_lan1(vm)
      end

      Scenarios.Device.await(vm, "LAN1 device returned with address", &addressed?/1)
    end
  end
end
