defmodule Scenarios.Cases.Latency do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device
  alias Scenarios.Qemu, as: Qemu

  def spec,
    do: %{
      :name => "real HTTPS survives 200ms upstream delay without losing management",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    Scenarios.Device.await(vm, "public Internet reachable", &internet?/1, 60_000)

    try do
      Qemu.network(vm, %{uplink: %{delay_ms: 200}})
      before = Scenarios.Qemu.network_stats(vm)
      assert {:ok, 200} = Qemu.internet_request(vm)
      assert addressed?(Scenarios.Device.status(vm))
      stats = Scenarios.Qemu.network_stats(vm)
      assert stats.delayed > 0
      assert stats.min_delay_ms >= 200
      assert stats.overflow == before.overflow
    after
      Qemu.network(vm, %{uplink: %{delay_ms: 0}})
    end

    Scenarios.Device.await(vm, "normal upstream restored", &internet?/1, 60_000)
  end
end
