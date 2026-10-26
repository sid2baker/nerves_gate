defmodule Scenarios.Cases.Sdk do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.Device
  alias NervesGateSDK.{CAN, Events, Network, RS485, Storage}
  alias NervesGateSDK.System.Info

  def spec do
    %{
      name: "SDK exposes typed reads and rejects unmanaged resource access",
      requires: %{device: [], fixture: []}
    }
  end

  def run(%{device: device}) do
    assert {:ok, %Info{} = info} = Device.rpc(device, NervesGateSDK.System, :info)
    assert is_binary(info.id) and info.id != ""
    assert is_binary(info.model) and info.model != ""
    assert is_nil(info.uptime_ms) or (is_integer(info.uptime_ms) and info.uptime_ms >= 0)
    assert {:ok, _} = Version.parse(info.sdk_version)
    refute Map.has_key?(info, :node)
    refute Map.has_key?(info, :cookie)
    assert {:ok, interfaces} = Device.rpc(device, Network, :interfaces)
    assert Enum.all?(interfaces, &is_struct(&1, Network.Interface))

    assert Enum.all?(
             interfaces,
             &(is_boolean(&1.application_enabled?) and is_boolean(&1.claimed?))
           )

    assert {:error, "application_not_running"} = Device.rpc(device, Network, :local_status)

    assert {:error, :invalid_local_network} =
             Device.rpc(device, Network, :claim_local, ["usb0", "192.168.50.2", 24])

    assert {:error, "application_not_running"} =
             Device.rpc(device, Network, :release_local, [make_ref()])

    assert {:ok, %Storage.Status{}} = Device.rpc(device, Storage, :status)

    assert {:error, :application_not_running} =
             Device.rpc(device, Storage, :data_dir, [:sdk_fixture])

    assert {:ok, can} = Device.rpc(device, CAN, :interfaces)
    assert Enum.all?(can, &is_struct(&1, CAN.Interface))
    assert {:ok, serial} = Device.rpc(device, RS485, :ports)
    assert Enum.all?(serial, &is_struct(&1, RS485.Port))
    assert {:error, :application_not_running} = Device.rpc(device, Events, :subscribe, [:system])
    assert {:error, :application_not_running} = Device.rpc(device, RS485, :claim, ["rs485_1"])
    assert {:error, :invalid_port} = Device.rpc(device, RS485, :claim, [123])
    assert {:error, :invalid_topic} = Device.rpc(device, Events, :subscribe, [:remote])

    assert {:error, :invalid_request} =
             Device.rpc(device, NervesGate.SDKBackend, :call, [:reboot, []])
  end
end
