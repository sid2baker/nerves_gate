defmodule NervesGateSim.Scenarios.TrialFault do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGateSim.ScenarioHelpers
  alias NervesGateSim.TestQemu, as: Qemu

  def spec, do: %{:name => "cable loss does not prevent saving a valid offline configuration"}

  def run(%{device: vm}) do
    saved = settings("eth0")
    save(vm, saved)
    Qemu.network(vm, %{internet: :lan2})
    trial = propose(vm, settings("eth1"))

    try do
      Qemu.network(vm, %{cables: %{lan2: false}})

      Qemu.await(vm, "trial lost its selected Ethernet link", fn status ->
        Enum.any?(status.connections.ports, &match?(%{name: "eth1", link: false}, &1))
      end)

      assert :ok = Qemu.call(vm, :network_confirm, [trial])

      Qemu.await(vm, "offline configuration saved", fn status ->
        status.network.pending == nil && not status.network.recovering &&
          status.network.desired == settings("eth1") && status.network.setup_completed
      end)
    after
      Qemu.network(vm, %{cables: %{lan2: true}})
    end

    Qemu.await(vm, "saved offline port acquired an address", &addressed?(&1, "eth1"))
  end
end
