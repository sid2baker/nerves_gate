defmodule NervesGate.Scenarios.PowerSaved do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def name, do: "confirmed configuration survives abrupt QEMU process loss"

  def run(vm) do
    saved = settings("eth0")
    save(vm, saved)
    restarted = Qemu.power_cycle(vm)

    restored =
      Qemu.await(restarted, "saved settings after VM process crash", fn status ->
        status.network.setup_completed && status.network.desired == saved &&
          not status.network.recovering && addressed?(status)
      end)

    assert restored.network.pending == nil
  end
end
