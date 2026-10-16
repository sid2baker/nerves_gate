defmodule NervesGate.Scenarios.TrialExpiry do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def spec, do: %{:name => "unconfirmed settings expire and restore the saved network"}

  def run(%{device: vm}) do
    saved = save(vm, settings("eth0"))
    trial = propose(vm, settings("eth1"))
    assert Qemu.status(vm).network.pending.id == trial

    restored =
      Qemu.await(
        vm,
        "trial expired and saved settings restored",
        fn status ->
          status.network.pending == nil && not status.network.recovering &&
            status.network.desired == saved && addressed?(status)
        end,
        80_000
      )

    assert restored.network.setup_completed
    assert {:error, %{code: "no_matching_trial"}} = Qemu.call(vm, :network_confirm, [trial])
  end
end
