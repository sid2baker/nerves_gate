defmodule Scenarios.Cases.Churn do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device

  def spec,
    do: %{
      :name => "three apply cancel and save cycles do not retain stale trials",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    saved = save(vm, settings("eth0"))

    for _ <- 1..3 do
      trial = propose(vm, settings("eth1"))
      assert :ok = Scenarios.Device.rpc(vm, NervesGate.Network, :cancel, [trial])

      Scenarios.Device.await(
        vm,
        "cancel restored saved settings",
        &(&1.network.pending == nil && not &1.network.recovering && &1.network.desired == saved)
      )

      assert {:error, %{code: "no_matching_trial"}} =
               Scenarios.Device.rpc(vm, NervesGate.Network, :confirm, [trial])

      assert settings("eth1") == save(vm, settings("eth1"))
      assert saved == save(vm, saved)
    end

    assert_port_arrangements(vm, saved)
    Scenarios.Device.await(vm, "DHCP address after port churn", &addressed?/1)
  end

  defp assert_port_arrangements(vm, saved) do
    legacy = %{"mode" => "shared", "equipment" => saved["eth0"]["address"]}
    assert {:error, _} = Scenarios.Device.rpc(vm, NervesGate.Network, :propose, [legacy])
    assert Scenarios.Device.status(vm).network.desired == saved
    enabled = Map.put(saved, "eth1", %{"role" => "application", "address" => nil})
    trial = propose(vm, enabled)
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.Network, :cancel, [trial])

    Scenarios.Device.await(
      vm,
      "application enablement cancelled",
      &(&1.network.pending == nil and &1.network.desired == saved and not &1.network.recovering)
    )

    assert enabled == save(vm, enabled)
    observed = Scenarios.Device.status(vm).network.observed
    assert Enum.all?(observed.ports, &is_nil(&1.master))
    assert Enum.any?(observed.ports, &(&1.name == "eth1" and &1.addresses == []))
    assert saved == save(vm, saved)
  end
end
