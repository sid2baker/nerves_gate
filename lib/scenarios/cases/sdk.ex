defmodule Scenarios.Cases.Sdk do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.Device, as: Device
  alias NervesGateSDK.{CAN, Events, Network, RS485, Storage}
  alias NervesGateSDK.System.Info

  def spec do
    %{
      name: "SDK exposes typed resources without board-specific assumptions",
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

    assert {:ok, nil} = Device.rpc(device, Network, :local_status)

    assert {:error, :invalid_local_network} =
             Device.rpc(device, Network, :claim_local, ["usb0", "192.168.50.2", 24])

    assert {:error, "not_owner"} = Device.rpc(device, Network, :release_local, [make_ref()])
    assert {:ok, %Storage.Status{}} = Device.rpc(device, Storage, :status)
    assert {:ok, can} = Device.rpc(device, CAN, :interfaces)
    assert Enum.all?(can, &is_struct(&1, CAN.Interface))
    assert {:ok, serial} = Device.rpc(device, RS485, :ports)
    assert Enum.all?(serial, &is_struct(&1, RS485.Port))

    # The SDK never grants platform administration, regardless of board hardware.
    assert {:error, :invalid_port} = Device.rpc(device, RS485, :claim, [123])
    assert {:error, :invalid_topic} = Device.rpc(device, Events, :subscribe, [:remote])

    assert {:error, :invalid_request} =
             Device.rpc(device, NervesGate.SDKBackend, :call, [:reboot, []])

    assert_subscriber_lifecycle(device)
  end

  defp assert_subscriber_lifecycle(device) do
    parent = self()
    server = {NervesGate.SDKBackend, device.node}

    client =
      spawn_link(fn ->
        :ok = GenServer.call(server, {:events_subscribe, [:network]})
        send(parent, {:subscribed, self()})

        receive do
          :stop -> :ok
        end
      end)

    try do
      assert_receive {:subscribed, ^client}, 5_000
      assert :ok = GenServer.call(server, {:events_subscribe, [:storage]})
      assert :ok = GenServer.call(server, {:events_unsubscribe, [:storage]})

      refute Map.has_key?(
               Device.rpc(device, :sys, :get_state, [NervesGate.SDKBackend]).monitors,
               self()
             )
    after
      send(client, :stop)
    end

    Device.await(device, "SDK releases dead subscribers", fn _ ->
      state = Device.rpc(device, :sys, :get_state, [NervesGate.SDKBackend])
      not Map.has_key?(state.monitors, client)
    end)
  end
end
