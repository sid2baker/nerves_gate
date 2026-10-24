defmodule Scenarios.Cases.ReceiveStall do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device

  def spec,
    do: %{
      :name => "LAN1 receive stall leaves carrier up and DHCP recovers when released",
      :fresh_disk => true,
      :boot => [receive_stall: true],
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    try do
      Scenarios.Device.await(vm, "carrier without an address", &addressed?(&1, "eth0", false))

      for _ <- 1..10 do
        Process.sleep(1_000)
        status = Scenarios.Device.status(vm)
        assert status.system.target == "x86_64"

        assert addressed?(status, "eth0", false)

        refute status.connections.internet.health == "online"
      end
    after
      Scenarios.Qemu.release_lan1_receive(vm)
    end

    Scenarios.Device.await(
      vm,
      "DHCP recovered after receive buffer released",
      &addressed?/1,
      60_000
    )
  end
end
