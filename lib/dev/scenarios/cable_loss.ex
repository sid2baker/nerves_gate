defmodule Dev.Scenarios.CableLoss do
  @moduledoc false
  import ExUnit.Assertions
  alias Dev.TestDevice, as: Device
  alias NervesGateSDK.{Events, Network}

  def spec do
    %{
      name: "Ethernet cable loss, SDK events and recovery",
      requires: %{device: [:ethernet], fixture: [:ethernet_link]}
    }
  end

  def run(%{device: device}) do
    before = Device.status(device)
    port = Enum.find(before.connections.ports, &(&1.role == "internet"))
    assert port != nil, "Prepare a separate Ethernet Internet port before running cable_loss"
    assert port.link and port.addresses != [], "The Ethernet Internet port must have an address"

    # A direct distributed call preserves the subscriber PID, unlike an RPC
    # worker that exits as soon as subscribe returns.
    server = {NervesGate.SDKBackend, device.node}
    assert :ok = GenServer.call(server, {:events_subscribe, [:network]})

    # The fixture must preserve an independent management path. Never change
    # product network settings to make a target fit this test.
    try do
      assert :ok = Device.control(device, :ethernet_link, [port.name, false])
      await_down(port.name, System.monotonic_time(:millisecond) + 10_000)

      Device.await(device, "cable disconnected", fn status ->
        Enum.any?(status.connections.ports, &(&1.name == port.name and not &1.link))
      end)
    after
      assert :ok = Device.control(device, :ethernet_link, [port.name, true])
      assert :ok = GenServer.call(server, {:events_unsubscribe, [:network]})
    end

    recovered =
      Device.await(device, "link and address recovered", fn status ->
        Enum.any?(
          status.connections.ports,
          &(&1.name == port.name and &1.link and &1.addresses != [])
        )
      end)

    assert recovered.network.desired == before.network.desired
    assert recovered.network.pending == before.network.pending
  end

  defp await_down(interface, deadline) do
    receive do
      %Events.Event{topic: :network, value: interfaces} ->
        assert Enum.all?(interfaces, &is_struct(&1, Network.Interface))

        unless Enum.any?(interfaces, &(&1.id == interface and &1.state == :down)),
          do: await_down(interface, deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> flunk("No SDK cable-loss event")
    end
  end
end
