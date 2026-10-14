defmodule NervesGate.Scenarios.Churn do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def name, do: "three apply cancel and save cycles do not retain stale trials"

  def run(vm) do
    saved = save(vm, settings("eth0"))

    for _ <- 1..3 do
      trial = propose(vm, settings("eth1"))
      assert :ok = Qemu.call(vm, :network_cancel, [trial])

      Qemu.await(
        vm,
        "cancel restored saved settings",
        &(&1.network.pending == nil && not &1.network.recovering && &1.network.desired == saved)
      )

      assert {:error, %{code: "no_matching_trial"}} = Qemu.call(vm, :network_confirm, [trial])
      assert settings("eth1") == save(vm, settings("eth1"))
      assert saved == save(vm, saved)
    end

    assert addressed?(Qemu.status(vm))
  end
end
