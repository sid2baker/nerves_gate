defmodule Scenarios.Cases.QemuSdk do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.{Device, ManagedPlugin}

  def spec,
    do: %{
      name: "Managed SDK assignment queries and subscriber ownership",
      fresh_disk: true,
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    # Plugin discovery runs after boot; assignment answers operation_in_progress until then.
    ManagedPlugin.await_idle(vm)
    assert {:ok, info} = Device.rpc(vm, NervesGateSDK.System, :info)
    assert info.model == "x86_64"
    assert {:error, :plugin_not_running} = Device.rpc(vm, NervesGateSDK.Hardware, :resources)
    # QEMU exposes only virtual Ethernet ports, never RS485/CAN resources.
    inventory = Device.rpc(vm, NervesGate.Hardware, :inventory)

    assert Enum.map(inventory, &{&1.name, &1.transport}) == [
             {"eth0", "ethernet"},
             {"eth1", "ethernet"}
           ]

    assert {:error, :hardware_missing} =
             Device.rpc(vm, NervesGate.Plugins, :assign_port, ["ttyS3", true, "modbus_plugin"])

    ManagedPlugin.with_plugin(vm, fn client ->
      assert {:ok, []} = ManagedPlugin.call(vm, client, NervesGateSDK.Hardware, :resources)
      subscriber = ManagedPlugin.client(vm)

      assert :ok =
               ManagedPlugin.call(vm, subscriber, NervesGateSDK.Events, :subscribe, [:network])

      assert :ok =
               ManagedPlugin.call(vm, subscriber, NervesGateSDK.Events, :subscribe, [:storage])

      assert :ok =
               ManagedPlugin.call(vm, subscriber, NervesGateSDK.Events, :unsubscribe, [:storage])

      assert Map.has_key?(
               Device.rpc(vm, :sys, :get_state, [NervesGate.SDKBackend]).monitors,
               subscriber
             )

      assert :ok = ManagedPlugin.stop_client(vm, subscriber)

      Device.await(vm, "dead managed subscriber is removed", fn _ ->
        not Map.has_key?(
          Device.rpc(vm, :sys, :get_state, [NervesGate.SDKBackend]).monitors,
          subscriber
        )
      end)
    end)
  end
end
