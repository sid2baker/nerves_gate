defmodule Scenarios.Cases.PluginLan do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device
  alias Scenarios.Qemu, as: Qemu

  def spec,
    do: %{
      :name => "plugin LAN cable failure leaves Internet and management available",
      fresh_disk: true,
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    before = Scenarios.Device.status(vm).network.desired

    network =
      Map.put(settings("eth0"), "eth1", %{"role" => "plugin", "address" => nil})

    save(vm, network)

    # The other editor must not silently replace settings saved since its draft began.
    assert {:error, %{code: "stale_network"}} =
             Scenarios.Device.rpc(vm, NervesGate.Network, :propose, [before, [expected: before]])

    assert Scenarios.Device.status(vm).network.desired == network
    assert Scenarios.Device.status(vm).network.pending == nil

    Scenarios.Device.await(
      vm,
      "Internet reachable before plugin LAN failure",
      &internet?/1,
      60_000
    )

    try do
      Qemu.network(vm, %{cables: %{lan2: false}})

      failed =
        Scenarios.Device.await(vm, "plugin LAN cable disconnected", fn status ->
          assert internet?(status), "Plugin LAN failure must not take down the Internet port"
          Enum.any?(status.connections.ports, &match?(%{name: "eth1", link: false}, &1))
        end)

      assert failed.network.desired == network
      assert failed.device.available
    after
      Qemu.network(vm, %{cables: %{lan2: true}})
    end

    Scenarios.Device.await(vm, "application link and Internet recovered", fn status ->
      internet?(status) && Enum.any?(status.connections.ports, &(&1.name == "eth1" and &1.link))
    end)

    assert_plugin_link(vm, network)
  end

  defp assert_plugin_link(vm, previous) do
    enabled = Map.put(previous, "eth1", %{"role" => "plugin", "address" => nil})
    save(vm, enabled)

    Scenarios.ManagedPlugin.with_plugin(
      vm,
      fn other ->
        owner = Scenarios.ManagedPlugin.client(vm)

        assert {:ok, ref} =
                 Scenarios.ManagedPlugin.call(vm, owner, NervesGateSDK.Network, :claim_local, [
                   "eth1",
                   "10.44.0.2",
                   24
                 ])

        Scenarios.Device.await(
          vm,
          "application address ready without changing Internet",
          fn status ->
            internet?(status) && addressed?(status, "eth1") &&
              status.network.local.phase == :configured
          end
        )

        assert {:error, "not_owner"} =
                 Scenarios.ManagedPlugin.call(vm, other, NervesGateSDK.Network, :release_local, [
                   ref
                 ])

        assert {:error, %{code: "local_in_use"}} =
                 Scenarios.Device.rpc(vm, NervesGate.Network, :propose, [previous])

        assert :ok = Scenarios.ManagedPlugin.stop_client(vm, owner)

        Scenarios.Device.await(
          vm,
          "owner death cleans local address while preserving Internet",
          fn status ->
            internet?(status) && status.network.local == nil &&
              Enum.any?(status.connections.ports, &(&1.name == "eth1" && &1.addresses == []))
          end,
          75_000
        )
      end,
      assigned_ports: ["eth1"]
    )

    save(vm, previous)
  end
end
