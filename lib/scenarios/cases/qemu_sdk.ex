defmodule Scenarios.Cases.QemuSdk do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.{Device, ManagedApp}

  def spec,
    do: %{
      name: "Managed SDK assignment queries and subscriber ownership",
      fresh_disk: true,
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    assert {:ok, info} = Device.rpc(vm, NervesGateSDK.System, :info)
    assert info.model == "x86_64"
    assert {:error, :application_not_running} = Device.rpc(vm, NervesGateSDK.Hardware, :resources)
    assert [] = Device.rpc(vm, NervesGate.Hardware, :inventory)

    assert {:error, :hardware_missing} =
             Device.rpc(vm, NervesGate.Plugins, :assign_port, ["ttyS3", true, "modbus_plugin"])

    ManagedApp.with_app(vm, fn client ->
      assert {:ok, []} = ManagedApp.call(vm, client, NervesGateSDK.Hardware, :resources)
      subscriber = ManagedApp.client(vm)
      assert :ok = ManagedApp.call(vm, subscriber, NervesGateSDK.Events, :subscribe, [:network])
      assert :ok = ManagedApp.call(vm, subscriber, NervesGateSDK.Events, :subscribe, [:storage])
      assert :ok = ManagedApp.call(vm, subscriber, NervesGateSDK.Events, :unsubscribe, [:storage])

      assert Map.has_key?(
               Device.rpc(vm, :sys, :get_state, [NervesGate.SDKBackend]).monitors,
               subscriber
             )

      assert :ok = ManagedApp.stop_client(vm, subscriber)

      Device.await(vm, "dead managed subscriber is removed", fn _ ->
        not Map.has_key?(
          Device.rpc(vm, :sys, :get_state, [NervesGate.SDKBackend]).monitors,
          subscriber
        )
      end)
    end)
  end
end
