defmodule Scenarios.Cases.TrialExpiry do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device

  def spec,
    do: %{
      :name => "unconfirmed settings expire and restore the saved network",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    saved = save(vm, settings("eth0"))
    trial = propose(vm, settings("eth1"))
    assert Scenarios.Device.status(vm).network.pending.id == trial

    restored =
      Scenarios.Device.await(
        vm,
        "trial expired and saved settings restored",
        fn status ->
          status.network.pending == nil && not status.network.recovering &&
            status.network.desired == saved && addressed?(status)
        end,
        80_000
      )

    assert restored.network.setup_completed

    assert {:error, %{code: "no_matching_trial"}} =
             Scenarios.Device.rpc(vm, NervesGate.Network, :confirm, [trial])
  end
end
