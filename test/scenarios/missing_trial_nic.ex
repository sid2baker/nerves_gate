defmodule NervesGate.Scenarios.MissingTrialNic do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def spec,
    do: %{
      :name => "removing the proposed Internet NIC prevents confirmation and permits rollback"
    }

  def run(%{device: vm}) do
    saved = settings("eth1")
    save(vm, saved)
    trial = propose(vm, settings("eth0"))

    try do
      NervesGate.TestQemu.remove_lan1(vm)

      Qemu.await(vm, "required trial NIC removed", fn status ->
        Enum.any?(status.connections.ports, &match?(%{name: "eth0", present: false}, &1)) &&
          not status.actions["network.confirm"].enabled
      end)

      assert {:error, %{code: "not_connected"}} = Qemu.call(vm, :network_confirm, [trial])

      Qemu.await(vm, "same trial available for cancellation", fn status ->
        match?(%{id: ^trial}, status.network.pending) && status.actions["network.cancel"].enabled
      end)

      assert :ok = Qemu.call(vm, :network_cancel, [trial])

      Qemu.await(vm, "confirmed topology restored without removed NIC", fn status ->
        status.network.pending == nil && not status.network.recovering &&
          status.network.desired == saved
      end)
    after
      NervesGate.TestQemu.insert_lan1(vm)
    end

    Qemu.await(vm, "removed NIC returned without changing settings", fn status ->
      status.network.desired == saved &&
        Enum.any?(status.connections.ports, &match?(%{name: "eth0", present: true}, &1))
    end)
  end
end
