defmodule TailnetSubrouterTest do
  use ExUnit.Case, async: false
  alias NervesGateSDK.Network.Local

  test "startup is disabled and enable requires explicit configuration" do
    assert TailnetSubrouter.status() == %{state: :disabled}
    assert TailnetSubrouter.enable() == {:error, :configure_first}
    assert TailnetSubrouter.disable() == :ok
    assert TailnetSubrouter.health_check() == :ok
    assert {:error, reason} = TailnetSubrouter.interfaces()
    assert reason in [:runtime_unavailable, :unavailable]
    assert TailnetSubrouter.status() == %{state: :disabled}
  end

  test "application status excludes the private claim handle" do
    lease = %Local{
      ref: make_ref(),
      interface: "eth1",
      address: "192.168.50.2",
      prefix: 24,
      subnet: "192.168.50.0/24",
      phase: :advertised,
      ready?: true,
      advertised?: true
    }

    status = TailnetSubrouter.public_status({:ok, lease})
    assert status.subnet == "192.168.50.0/24"
    assert status.tailnet_approval == :unknown
    refute Map.has_key?(status, :ref)
    refute inspect(status) =~ "#Reference"
    assert TailnetSubrouter.public_status({:error, :unavailable}).state == :unavailable
  end
end
