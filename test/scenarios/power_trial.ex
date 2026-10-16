defmodule NervesGate.Scenarios.PowerTrial do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def spec, do: %{:name => "VM process loss during a trial restores only confirmed settings"}

  def run(%{device: vm}) do
    saved = settings("eth0")
    save(vm, saved)
    trial = propose(vm, settings("eth1"))
    restarted = Qemu.power_cycle(vm)

    restored =
      Qemu.await(restarted, "unconfirmed trial discarded after process crash", fn status ->
        status.network.pending == nil && not status.network.recovering &&
          status.network.desired == saved && addressed?(status)
      end)

    assert restored.network.setup_completed

    assert {:error, %{code: "no_matching_trial"}} =
             Qemu.call(restarted, :network_confirm, [trial])
  end
end
