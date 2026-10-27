defmodule NervesGateSDK.APITest do
  use ExUnit.Case, async: false
  alias NervesGateSDK.{Events, Hardware, Network, Storage}

  test "capabilities fail explicitly without a running gateway" do
    assert {:error, _} = NervesGateSDK.System.info()
    assert {:error, _} = Network.interfaces()
    assert {:error, _} = Network.claim_local("eth1", "192.168.50.2", 24)
    assert {:error, _} = Network.local_status()
    assert {:error, _} = Network.advertise_local(make_ref())
    assert {:error, _} = Network.release_local(make_ref())
    assert {:error, _} = Events.subscribe(:network)
    assert {:error, _} = Events.unsubscribe(:network)
    assert {:error, _} = Storage.status()
    assert {:error, _} = Storage.data_dir(:example)
    assert {:error, _} = Hardware.resources()
  end

  test "invalid input never reaches the firmware" do
    assert {:error, :invalid_topic} = Events.subscribe(:credentials)
    assert {:error, :invalid_local_network} = Network.claim_local("usb0", "192.168.50.2", 24)
    assert {:error, :invalid_local_network} = Network.claim_local("eth1", "192.168.50.2", 32)
    assert {:error, :invalid_claim} = Network.advertise_local(:anything)
    assert {:error, :invalid_claim} = Network.release_local(:anything)
    assert {:error, :invalid_application} = Storage.data_dir(:"../platform")
    assert {:error, :invalid_application} = Storage.data_dir("example")
  end

  test "fixed firmware bridge is optional at compile time" do
    expected =
      if Code.ensure_loaded?(NervesGate.SDKBackend), do: :unavailable, else: :runtime_unavailable

    assert {:error, ^expected} = NervesGateSDK.System.info()
  end
end
