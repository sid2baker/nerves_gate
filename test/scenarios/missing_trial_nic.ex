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
    status = Qemu.await(vm, "trial DHCP address before removal", &addressed?/1)
    port = Enum.find(status.connections.ports, &(&1.name == "eth0"))
    manager = :erpc.call(vm.node, Process, :whereis, [VintageNet.RouteManager])
    assert is_pid(manager)

    try do
      Qemu.remove_lan1(vm)

      # Unplug can race an already-running kernel route command. Exercise that
      # supervisor recovery deterministically, not only when CI happens to hit it.
      assert :erpc.call(vm.node, Process, :exit, [manager, :kill])

      await_recovery(vm, trial, manager)

      manager = :erpc.call(vm.node, Process, :whereis, [VintageNet.RouteManager])
      assert_late_route_ignored(vm, port)
      assert ^manager = :erpc.call(vm.node, Process, :whereis, [VintageNet.RouteManager])
      assert {:error, %{code: "not_connected"}} = Qemu.call(vm, :network_confirm, [trial])
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

  defp await_recovery(vm, trial, manager) do
    Qemu.await(vm, "same trial after interface-manager recovery", fn status ->
      observed = status.network.observed
      removed = Enum.find(observed.ports, &(&1.name == "eth0"))

      remaining = [
        observed.bridge,
        observed.usb | Enum.reject(observed.ports, &(&1.name == "eth0"))
      ]

      current = :erpc.call(vm.node, Process, :whereis, [VintageNet.RouteManager])

      is_pid(current) && current != manager && match?(%{id: ^trial}, status.network.pending) &&
        match?(%{present: false, state: :retrying}, removed) &&
        Enum.all?(remaining, &(&1.state == :configured)) &&
        not status.actions["network.confirm"].enabled
    end)
  end

  defp assert_late_route_ignored(vm, port) do
    # Deliver a late lease/connectivity report after physical removal. These are
    # VintageNet's real routing APIs, not a fake adapter or injected server state.
    [%{address: address, prefix_length: prefix} | _] = port.addresses
    {:ok, address} = :inet.parse_ipv4_address(String.to_charlist(address))
    {:ok, gateway} = :inet.parse_ipv4_address(String.to_charlist(port.gateway))

    assert :ok =
             :erpc.call(vm.node, VintageNet.RouteManager, :set_connection_status, [
               "eth0",
               :disconnected,
               "missing NIC scenario"
             ])

    assert :ok =
             :erpc.call(vm.node, VintageNet.RouteManager, :set_route, [
               "eth0",
               [{address, prefix}],
               gateway
             ])

    assert :ok =
             :erpc.call(vm.node, VintageNet.RouteManager, :set_connection_status, [
               "eth0",
               :internet,
               "late connectivity report"
             ])
  end
end
