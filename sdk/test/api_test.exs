defmodule NervesGateSDK.APITest do
  use ExUnit.Case, async: false
  alias NervesGateSDK.{CAN, Events, Network, RS485, Storage}

  test "valid capabilities report errors without running gateway services" do
    assert {:error, _} = NervesGateSDK.System.info()
    assert {:error, _} = NervesGateSDK.Network.interfaces()

    assert {:error, _} = NervesGateSDK.Network.claim_local("eth1", "192.168.50.2", 24)

    assert {:error, _} = NervesGateSDK.Network.local_status()
    local = make_ref()
    assert {:error, _} = NervesGateSDK.Network.advertise_local(local)
    assert {:error, _} = NervesGateSDK.Network.release_local(local)
    assert {:error, _} = NervesGateSDK.Events.subscribe(:network)
    assert {:error, _} = NervesGateSDK.Events.unsubscribe(:network)
    assert {:error, _} = NervesGateSDK.Storage.status()
    assert {:error, _} = NervesGateSDK.Storage.data_dir(:example)
    assert {:error, _} = NervesGateSDK.CAN.interfaces()
    assert {:error, _} = NervesGateSDK.CAN.subscribe("can0")
    assert {:error, _} = NervesGateSDK.CAN.unsubscribe("can0")
    frame = %CAN.Frame{id: 1, data: <<1>>}
    assert {:error, _} = NervesGateSDK.CAN.send("can0", frame)
    assert {:error, _} = NervesGateSDK.RS485.ports()
    assert {:error, _} = NervesGateSDK.RS485.claim("rs485_1")
    claim = make_ref()
    assert {:error, _} = NervesGateSDK.RS485.write(claim, <<1>>)
    assert {:error, _} = NervesGateSDK.RS485.release(claim)
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

  test "the fixed firmware entry point is optional at SDK compile time" do
    if Code.ensure_loaded?(NervesGate.SDKBackend) do
      # Root host checks also load firmware code, but do not start its services.
      assert {:error, :unavailable} = NervesGateSDK.System.info()
    else
      assert {:error, :runtime_unavailable} = NervesGateSDK.System.info()
    end
  end
end
