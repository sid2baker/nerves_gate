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
    joined = %{"mode" => "shared", "equipment" => saved["eth0"]["address"]}

    trial = propose(vm, joined)
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.Network, :cancel, [trial])

    Scenarios.Device.await(
      vm,
      "joining cancelled",
      &(&1.network.pending == nil and &1.network.desired == saved and not &1.network.recovering)
    )

    assert joined == save(vm, joined)
    observed = Scenarios.Device.status(vm).network.observed
    # Saving checks topology, not a DHCP lease or Internet access.
    assert %{present: true, state: :configured} = observed.bridge
    assert Enum.all?(observed.ports, &(&1.master == "br0"))
    separate = %{"mode" => "ports", "eth0" => nil, "eth1" => nil}
    assert separate == save(vm, separate)
    assert saved == save(vm, saved)
  end
end
