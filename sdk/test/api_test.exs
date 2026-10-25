defmodule NervesGateSDK.APITest do
  use ExUnit.Case, async: false
  alias NervesGateSDK.{CAN, Equipment, Events, Network, RS485, Storage}

  defmodule RecordingBackend do
    @behaviour NervesGateSDK.Backend
    @impl true
    def call(operation, arguments), do: {:ok, {operation, arguments}}
  end

  setup do
    previous = Application.get_env(:nerves_gate_sdk, :backend)
    Application.put_env(:nerves_gate_sdk, :backend, RecordingBackend)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nerves_gate_sdk, :backend, previous),
        else: Application.delete_env(:nerves_gate_sdk, :backend)
    end)
  end

  test "every application capability dispatches through Backend" do
    assert {:ok, {:system_info, []}} = NervesGateSDK.System.info()
    assert {:ok, {:network_interfaces, []}} = Network.interfaces()

    assert {:ok, {:network_claim_local, ["eth1", "192.168.50.2", 24]}} =
             Network.claim_local("eth1", "192.168.50.2", 24)

    assert {:ok, {:network_local_status, []}} = Network.local_status()
    local = make_ref()
    assert {:ok, {:network_advertise_local, [^local]}} = Network.advertise_local(local)
    assert {:ok, {:network_release_local, [^local]}} = Network.release_local(local)
    assert {:ok, {:events_subscribe, [:network]}} = Events.subscribe(:network)
    assert {:ok, {:events_unsubscribe, [:network]}} = Events.unsubscribe(:network)
    assert {:ok, {:storage_status, []}} = Storage.status()
    assert {:ok, {:storage_data_dir, [:example]}} = Storage.data_dir(:example)
    assert {:ok, {:can_interfaces, []}} = CAN.interfaces()
    assert {:ok, {:can_subscribe, ["can0"]}} = CAN.subscribe("can0")
    assert {:ok, {:can_unsubscribe, ["can0"]}} = CAN.unsubscribe("can0")
    frame = %CAN.Frame{id: 1, data: <<1>>}
    assert {:ok, {:can_send, ["can0", ^frame]}} = CAN.send("can0", frame)
    assert {:ok, {:rs485_ports, []}} = RS485.ports()
    assert {:ok, {:rs485_claim, ["rs485_1"]}} = RS485.claim("rs485_1")
    claim = make_ref()
    assert {:ok, {:rs485_write, [^claim, <<1>>]}} = RS485.write(claim, <<1>>)
    assert {:ok, {:rs485_release, [^claim]}} = RS485.release(claim)
    assert {:ok, {:equipment_list, []}} = Equipment.list()
  end

  test "invalid application input never reaches the backend" do
    assert {:error, :invalid_topic} = Events.subscribe(:credentials)
    assert {:error, :invalid_local_network} = Network.claim_local("usb0", "192.168.50.2", 24)
    assert {:error, :invalid_local_network} = Network.claim_local("eth1", "192.168.50.2", 32)
    assert {:error, :invalid_claim} = Network.advertise_local(:anything)
    assert {:error, :invalid_claim} = Network.release_local(:anything)
    assert {:error, :invalid_application} = Storage.data_dir(:"../platform")
    assert {:error, :invalid_application} = Storage.data_dir("example")
    assert {:error, :invalid_frame} = CAN.send("can0", %CAN.Frame{id: 2048, data: <<>>})
    assert {:error, :invalid_frame} = CAN.send("can0", %CAN.Frame{id: -1, data: <<>>})
    assert {:error, :invalid_frame} = CAN.send("can0", %CAN.Frame{id: 1, data: <<0::72>>})
    assert {:error, :invalid_write} = RS485.write(make_ref(), <<0::32776>>)
    assert {:error, :invalid_claim} = RS485.release(:not_a_claim)
  end

  test "classic and extended CAN bounds" do
    assert CAN.Frame.valid?(%CAN.Frame{id: 0x7FF, data: <<0::64>>})
    assert CAN.Frame.valid?(%CAN.Frame{id: 0x1FFFFFFF, data: <<>>, extended?: true})
    refute CAN.Frame.valid?(%CAN.Frame{id: 0x20000000, data: <<>>, extended?: true})
    refute CAN.Frame.valid?(%CAN.Frame{id: 1, data: "", remote?: :yes})
  end

  test "an unconfigured backend is explicit" do
    Application.delete_env(:nerves_gate_sdk, :backend)
    assert {:error, :backend_not_configured} = Network.interfaces()
  end
end
