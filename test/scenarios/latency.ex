defmodule NervesGate.Scenarios.Latency do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def name, do: "delayed upstream probes preserve connectivity and management"

  def run(vm) do
    Qemu.start_upstream(vm)
    save(vm, settings("eth0"))
    Qemu.await(vm, "upstream reachable", &internet?/1, 60_000)
    before = Qemu.probe_count(vm)

    try do
      Qemu.delay_internet(vm)

      Qemu.await(
        vm,
        "fresh probe succeeded with 200ms delay",
        fn status ->
          assert internet?(status)
          Qemu.probe_count(vm) > before
        end,
        60_000
      )
    after
      Qemu.clear_delay(vm)
    end

    Qemu.await(vm, "normal upstream restored", &internet?/1)
  end
end
