defmodule NervesGateSim.Scenarios.Equipment do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGateSim.ScenarioHelpers
  alias NervesGateSim.TestQemu, as: Qemu

  def spec, do: %{:name => "equipment cable failure leaves Internet and management available"}

  def run(%{device: vm}) do
    before = Qemu.status(vm).network.desired

    network =
      Map.put(settings("eth0"), "eth1", %{
        "role" => "equipment",
        "address" => %{
          "ip_method" => "static",
          "static_ip" => "10.44.0.1",
          "subnet_mask" => "255.255.255.0",
          "gateway" => nil
        }
      })

    save(vm, network)

    # The other editor must not silently replace settings saved since its draft began.
    assert {:error, %{code: "stale_network"}} =
             Qemu.call(vm, :network_propose, [before, [expected: before]])

    assert Qemu.status(vm).network.desired == network
    assert Qemu.status(vm).network.pending == nil
    Qemu.await(vm, "Internet reachable before equipment failure", &internet?/1, 60_000)

    try do
      Qemu.network(vm, %{cables: %{lan2: false}})

      failed =
        Qemu.await(vm, "equipment cable disconnected", fn status ->
          assert internet?(status), "Equipment failure must not take down the Internet port"
          Enum.any?(status.connections.ports, &match?(%{name: "eth1", link: false}, &1))
        end)

      assert failed.network.desired == network
      assert failed.backend.available
    after
      Qemu.network(vm, %{cables: %{lan2: true}})
    end

    Qemu.await(vm, "equipment and Internet recovered", fn status ->
      internet?(status) && addressed?(status, "eth1")
    end)
  end
end
