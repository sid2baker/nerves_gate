defmodule NervesGate.Scenarios.Sdk do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.TestQemu, as: Qemu
  alias NervesGateSDK.{CAN, Equipment, Events, Network, RS485, Storage}
  alias NervesGateSDK.System.Info

  def spec, do: %{name: "Device SDK exposes typed observations and caller-owned subscriptions"}

  def run(%{device: vm}) do
    assert {:ok, %Info{} = info} = call(vm, NervesGateSDK.System, :info)
    assert info.model == "x86_64"
    assert info.uptime_ms >= 0
    assert Version.match?(info.sdk_version, "~> 0.1.0")
    refute Map.has_key?(info, :node)
    refute Map.has_key?(info, :cookie)
    assert {:ok, interfaces} = call(vm, Network, :interfaces)
    assert Enum.all?(interfaces, &is_struct(&1, Network.Interface))
    assert Enum.any?(interfaces, &(&1.id == "eth0" and &1.kind == :ethernet))
    assert {:ok, %Storage.Status{}} = call(vm, Storage, :status)
    assert {:ok, equipment} = call(vm, Equipment, :list)
    assert Enum.all?(equipment, &is_struct(&1, Equipment.Device))

    # This kernel does not expose EC100 CAN/UART hardware. Unavailable devices
    # must not be replaced by firmware-side mocks or accept SDK traffic.
    assert {:ok, []} = call(vm, CAN, :interfaces)
    frame = %CAN.Frame{id: 123, data: <<1, 2, 3>>}
    assert {:error, :bus_unsupported} = call(vm, CAN, :send, ["can0", frame])
    assert {:error, :bus_unsupported} = call(vm, CAN, :subscribe, ["can0"])
    assert {:ok, ports} = call(vm, RS485, :ports)
    assert Enum.all?(ports, &match?(%RS485.Port{available?: false}, &1))
    assert {:error, :bus_unsupported} = call(vm, RS485, :claim, ["rs485_1"])
    assert {:error, :invalid_port} = call(vm, RS485, :claim, [123])
    assert {:error, :invalid_topic} = call(vm, Events, :subscribe, [:remote])
    assert {:error, :invalid_request} = call(vm, NervesGate.SDKBackend, :call, [:reboot, []])
    assert_can_codec(vm)
    assert_events(vm)
  end

  defp assert_events(vm) do
    parent = self()
    server = {NervesGate.SDKBackend, vm.node}

    client =
      spawn_link(fn ->
        # Direct distributed call preserves the subscriber PID (unlike a short-lived
        # RPC worker). The SDK uses this same call locally on the device.
        :ok = GenServer.call(server, {:events_subscribe, [:network]})
        send(parent, {:subscribed, self()})
        forward(parent)
      end)

    assert_receive {:subscribed, ^client}, 5_000
    assert :ok = GenServer.call(server, {:events_subscribe, [:storage]})
    assert :ok = GenServer.call(server, {:events_unsubscribe, [:storage]})
    refute Map.has_key?(call(vm, :sys, :get_state, [NervesGate.SDKBackend]).monitors, self())

    try do
      Qemu.network(vm, %{cables: %{lan1: false}})
      await_down(client)
    after
      Qemu.network(vm, %{cables: %{lan1: true}})
      send(client, :stop)
    end

    Qemu.await(vm, "SDK releases dead subscribers", fn _ ->
      state = call(vm, :sys, :get_state, [NervesGate.SDKBackend])
      not Map.has_key?(state.monitors, client)
    end)

    Qemu.await(vm, "SDK cable restored", &NervesGate.ScenarioHelpers.addressed?/1)
  end

  defp forward(parent) do
    receive do
      :stop ->
        :ok

      %Events.Event{} = event ->
        send(parent, {:sdk_event, self(), event})
        forward(parent)
    end
  end

  defp await_down(client, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000

    receive do
      {:sdk_event, ^client, %Events.Event{topic: :network, value: interfaces}} ->
        assert Enum.all?(interfaces, &is_struct(&1, Network.Interface))

        unless Enum.any?(interfaces, &(&1.id == "eth0" and &1.state == :down)),
          do: await_down(client, deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> flunk("No SDK cable-loss event")
    end
  end

  defp assert_can_codec(vm) do
    for frame <- [
          %CAN.Frame{id: 0x7FF, data: <<1, 2, 3>>},
          %CAN.Frame{id: 0x1FFFFFFF, data: <<0::64>>, extended?: true},
          %CAN.Frame{id: 42, data: <<>>, remote?: true}
        ] do
      packet = call(vm, NervesGate.Linux.CAN, :encode_frame, [frame])
      assert byte_size(packet) == 16
      assert ^frame = call(vm, NervesGate.Linux.CAN, :decode_frame, [packet])
    end

    assert nil == call(vm, NervesGate.Linux.CAN, :decode_frame, [<<0::128>> <> <<0>>])

    assert nil ==
             call(vm, NervesGate.Linux.CAN, :decode_frame, [<<0x20000000::native-32, 0::96>>])

    assert {:ok, %{listen_only: true}} =
             call(vm, NervesGate.Buses.Policy, :configure, [
               "can0",
               %{"enabled" => true, "bitrate" => 250_000}
             ])

    assert {:ok, %{listen_only: false}} =
             call(vm, NervesGate.Buses.Policy, :configure, [
               "can0",
               %{"enabled" => true, "bitrate" => 250_000, "listen_only" => false}
             ])
  end

  defp call(vm, module, function, args \\ []), do: :erpc.call(vm.node, module, function, args)
end
