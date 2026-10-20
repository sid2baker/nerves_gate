defmodule NervesGate.Scenarios.ReceiveStall do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def spec,
    do: %{
      :name => "LAN1 receive stall leaves carrier up and DHCP recovers when released",
      :fresh_disk => true,
      :boot => [receive_stall: true]
    }

  def run(%{device: vm}) do
    try do
      Qemu.await(vm, "carrier without an address", &addressed?(&1, "eth0", false))

      for _ <- 1..10 do
        Process.sleep(1_000)
        status = Qemu.status(vm)
        assert status.system.target == "x86_64"

        assert addressed?(status, "eth0", false)

        refute status.connections.internet.health == "online"
      end
    after
      NervesGate.TestQemu.release_lan1_receive(vm)
    end

    Qemu.await(vm, "DHCP recovered after receive buffer released", &addressed?/1, 60_000)
  end
end
