# Ordinary ExUnit scenarios; mix test.qemu supplies the isolated namespace.
ExUnit.start(timeout: 240_000)
{:ok, _} = Application.ensure_all_started(:muontrap)

defmodule NervesGate.QemuTest do
  use ExUnit.Case, async: false
  alias NervesGate.TestQemu, as: Qemu

  setup do
    vm = Qemu.start()
    Qemu.await(vm, "baseline link and address", &addressed?/1)
    %{vm: vm}
  end

  test "Ethernet cable loss and recovery", %{vm: vm} do
    cable_cycle(vm)
  end

  test "three consecutive cable failures recover", %{vm: vm} do
    for _ <- 1..3, do: cable_cycle(vm)
  end

  test "invalid configuration is rejected without losing management or changing settings", %{
    vm: vm
  } do
    before = Qemu.status(vm)
    invalid = %{"mode" => "not-a-mode"}
    assert {:error, %{code: "invalid_parameters"}} = Qemu.call(vm, :network_validate, [invalid])
    assert {:error, %{code: "invalid_parameters"}} = Qemu.call(vm, :network_propose, [invalid])
    after_rejection = Qemu.status(vm)
    assert after_rejection.network.desired == before.network.desired
    assert after_rejection.network.pending == nil
    assert addressed?(after_rejection)
  end

  test "confirmed settings survive a VM reset", %{vm: vm} do
    settings = %{
      "mode" => "ports",
      "eth0" => %{"role" => "internet", "address" => NervesGate.Config.address_defaults()},
      "eth1" => nil
    }

    Qemu.await(vm, "configuration available", & &1.actions["network.propose"].enabled)
    assert {:ok, trial} = Qemu.call(vm, :network_propose, [settings])
    Qemu.await(vm, "configuration ready to save", & &1.actions["network.confirm"].enabled)
    assert :ok = Qemu.call(vm, :network_confirm, [trial])
    Qemu.await(vm, "settings saved", &(&1.network.setup_completed && &1.network.pending == nil))

    Qemu.reboot(vm)

    restored =
      Qemu.await(vm, "saved configuration and DHCP restored", fn status ->
        status.network.setup_completed && status.network.desired == settings && addressed?(status)
      end)

    assert restored.network.pending == nil
  end

  defp cable_cycle(vm) do
    try do
      Qemu.disconnect_wan(vm)

      Qemu.await(vm, "cable disconnected", fn status ->
        Enum.any?(status.connections.ports, &match?(%{name: "eth0", link: false}, &1))
      end)
    after
      Qemu.reconnect_wan(vm)
    end

    Qemu.await(vm, "link and address recovered", &addressed?/1)
  end

  defp addressed?(status) do
    Enum.any?(
      status.connections.ports,
      &match?(%{name: "eth0", link: true, addresses: [_ | _]}, &1)
    )
  end
end
