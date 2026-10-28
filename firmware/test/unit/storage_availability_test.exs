defmodule NervesGate.StorageAvailabilityTest do
  # Registers the global NervesGate.Storage name.
  use ExUnit.Case, async: false
  alias NervesGate.Storage
  alias NervesGateSDK.Storage.Status

  test "a missing or unresponsive storage owner reads as unavailable storage" do
    assert Storage.root() == {:error, :storage_unavailable}
    assert {:ok, %Status{available?: false}} = Storage.status()
    assert Storage.data_dir("modbus_plugin") == {:error, :storage_unavailable}

    # Probing or mounting a card can keep the owner busy past the call timeout.
    owner = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(owner, Storage)

    try do
      assert {:ok, %Status{available?: false}} = Storage.status()
    after
      Process.exit(owner, :kill)
    end
  end
end
