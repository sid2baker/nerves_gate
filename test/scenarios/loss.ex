defmodule NervesGate.Scenarios.Loss do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def name, do: "intermittent upstream packet loss preserves management and recovers"

  def run(vm) do
    Qemu.start_upstream(vm)
    save(vm, settings("eth0"))
    Qemu.await(vm, "upstream reachable", &internet?/1, 60_000)
    before = Qemu.probe_count(vm)

    try do
      Qemu.lose_internet_packets(vm)

      Qemu.await(
        vm,
        "fresh probe completed despite intermittent loss",
        fn status ->
          assert addressed?(status)
          Qemu.probe_count(vm) > before
        end,
        60_000
      )

      assert Qemu.dropped_packets(vm) > 0
    after
      Qemu.restore_internet(vm)
    end

    Qemu.await(vm, "healthy upstream after packet loss removed", &internet?/1, 60_000)
  end
end
