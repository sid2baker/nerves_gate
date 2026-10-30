defmodule Scenarios.Cases.CableLoss do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.Device, as: Device
  alias Scenarios.ManagedPlugin
  alias NervesGateSDK.{Events, Network}

  def spec do
    %{
      name: "Ethernet cable loss, SDK events and recovery",
      requires: %{device: [:ethernet], fixture: [:qemu, :ethernet_link]}
    }
  end

  def run(%{device: device}) do
    before = Device.status(device)
    port = Enum.find(before.connections.ports, &(&1.role == "internet"))
    assert port != nil, "Prepare a separate Ethernet Internet port before running cable_loss"
    assert port.link and port.addresses != [], "The Ethernet Internet port must have an address"

    # SDK subscriptions belong to a managed plugin process; the real fixture
    # client subscribes in its own PID and buffers the typed events it receives.
    ManagedPlugin.with_plugin(device, fn client ->
      assert :ok = ManagedPlugin.call(device, client, Events, :subscribe, [:network])
      events(device, client)

      # The fixture must preserve an independent management path. Never change
      # product network settings to make a target fit this test.
      try do
        assert :ok = Device.control(device, :ethernet_link, [port.name, false])
        await_down(device, client, port.name, System.monotonic_time(:millisecond) + 10_000)

        Device.await(device, "cable disconnected", fn status ->
          Enum.any?(status.connections.ports, &(&1.name == port.name and not &1.link))
        end)
      after
        assert :ok = Device.control(device, :ethernet_link, [port.name, true])
      end
    end)

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

  defp await_down(device, client, interface, deadline) do
    network =
      for %Events.Event{topic: :network, value: value} <- events(device, client), do: value

    assert Enum.all?(List.flatten(network), &is_struct(&1, Network.Interface))

    cond do
      Enum.any?(network, fn interfaces ->
        Enum.any?(interfaces, &(&1.id == interface and &1.state == :down))
      end) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("No SDK cable-loss event")

      true ->
        Process.sleep(200)
        await_down(device, client, interface, deadline)
    end
  end

  defp events(device, client), do: Device.rpc(device, GenServer, :call, [client, :events])
end
