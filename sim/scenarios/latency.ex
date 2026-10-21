defmodule NervesGateSim.Scenarios.Latency do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGateSim.ScenarioHelpers
  alias NervesGateSim.TestQemu, as: Qemu

  def spec, do: %{:name => "real HTTPS survives 200ms upstream delay without losing management"}

  def run(%{device: vm}) do
    Qemu.await(vm, "public Internet reachable", &internet?/1, 60_000)

    try do
      Qemu.network(vm, %{uplink: %{delay_ms: 200}})
      before = NervesGateSim.TestQemu.network_stats(vm)
      assert {:ok, 200} = Qemu.internet_request(vm)
      assert addressed?(Qemu.status(vm))
      stats = NervesGateSim.TestQemu.network_stats(vm)
      assert stats.delayed > 0
      assert stats.min_delay_ms >= 200
      assert stats.overflow == before.overflow
    after
      Qemu.network(vm, %{uplink: %{delay_ms: 0}})
    end

    Qemu.await(vm, "normal upstream restored", &internet?/1, 60_000)
  end
end
