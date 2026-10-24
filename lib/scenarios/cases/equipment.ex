defmodule Scenarios.Cases.Equipment do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device
  alias Scenarios.Qemu, as: Qemu

  def spec,
    do: %{
      :name => "equipment cable failure leaves Internet and management available",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    before = Scenarios.Device.status(vm).network.desired

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
             Scenarios.Device.rpc(vm, NervesGate.Network, :propose, [before, [expected: before]])

    assert Scenarios.Device.status(vm).network.desired == network
    assert Scenarios.Device.status(vm).network.pending == nil

    Scenarios.Device.await(
      vm,
      "Internet reachable before equipment failure",
      &internet?/1,
      60_000
    )

    try do
      Qemu.network(vm, %{cables: %{lan2: false}})

      failed =
        Scenarios.Device.await(vm, "equipment cable disconnected", fn status ->
          assert internet?(status), "Equipment failure must not take down the Internet port"
          Enum.any?(status.connections.ports, &match?(%{name: "eth1", link: false}, &1))
        end)

      assert failed.network.desired == network
      assert failed.device.available
    after
      Qemu.network(vm, %{cables: %{lan2: true}})
    end

    Scenarios.Device.await(vm, "equipment and Internet recovered", fn status ->
      internet?(status) && addressed?(status, "eth1")
    end)
  end
end
