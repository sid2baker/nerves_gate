defmodule NervesGate.Scenarios.Latency do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def name, do: "real HTTPS survives 200ms upstream delay without losing management"

  def run(vm) do
    Qemu.await(vm, "public Internet reachable", &internet?/1, 60_000)

    try do
      Qemu.delay_internet(vm)
      assert {:ok, 200} = Qemu.internet_request(vm)
      assert addressed?(Qemu.status(vm))
    after
      Qemu.clear_delay(vm)
    end

    Qemu.await(vm, "normal upstream restored", &internet?/1, 60_000)
  end
end
