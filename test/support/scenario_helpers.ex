defmodule NervesGate.ScenarioHelpers do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.TestQemu, as: Qemu

  def settings(port) do
    Map.put(%{"mode" => "ports", "eth0" => nil, "eth1" => nil}, port, %{
      "role" => "internet",
      "address" => NervesGate.Config.address_defaults()
    })
  end

  def propose(vm, settings) do
    Qemu.await(vm, "configuration available", & &1.actions["network.propose"].enabled)
    assert {:ok, trial} = Qemu.call(vm, :network_propose, [settings])
    Qemu.await(vm, "configuration ready to save", & &1.actions["network.confirm"].enabled)
    trial
  end

  def save(vm, settings) do
    trial = propose(vm, settings)
    assert :ok = Qemu.call(vm, :network_confirm, [trial])

    Qemu.await(
      vm,
      "settings saved",
      &(&1.network.setup_completed && &1.network.pending == nil && &1.network.desired == settings)
    )

    settings
  end

  def cable_cycle(vm) do
    try do
      Qemu.network(vm, %{cables: %{lan1: false}})

      Qemu.await(vm, "cable disconnected", fn status ->
        Enum.any?(status.connections.ports, &match?(%{name: "eth0", link: false}, &1))
      end)
    after
      Qemu.network(vm, %{cables: %{lan1: true}})
    end

    Qemu.await(vm, "link and address recovered", &addressed?/1)
  end

  def internet?(status) do
    addressed?(status) && status.connections.internet.health == "online" &&
      Enum.any?(status.connections.ports, &match?(%{name: "eth0", connection: :internet}, &1))
  end

  def addressed?(status) do
    Enum.any?(
      status.connections.ports,
      &match?(%{name: "eth0", link: true, addresses: [_ | _]}, &1)
    )
  end
end
