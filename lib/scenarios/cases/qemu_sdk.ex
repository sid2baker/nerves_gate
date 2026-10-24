defmodule Scenarios.Cases.QemuSdk do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGateSDK.{CAN, RS485}

  def spec,
    do: %{
      name: "QEMU SDK rejects bus access when hardware is absent",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    assert {:ok, info} = Scenarios.Device.rpc(vm, NervesGateSDK.System, :info)
    assert info.model == "x86_64"

    # This kernel does not expose EC100 CAN/UART hardware. Unavailable devices
    # must not be replaced by firmware-side mocks or accept SDK traffic.
    assert {:ok, []} = Scenarios.Device.rpc(vm, CAN, :interfaces)
    frame = %CAN.Frame{id: 123, data: <<1, 2, 3>>}
    assert {:error, :bus_unsupported} = Scenarios.Device.rpc(vm, CAN, :send, ["can0", frame])
    assert {:error, :bus_unsupported} = Scenarios.Device.rpc(vm, CAN, :subscribe, ["can0"])
    assert {:ok, ports} = Scenarios.Device.rpc(vm, RS485, :ports)
    assert Enum.all?(ports, &match?(%RS485.Port{available?: false}, &1))
    assert {:error, :bus_unsupported} = Scenarios.Device.rpc(vm, RS485, :claim, ["rs485_1"])
    assert_can_codec(vm)
  end

  defp assert_can_codec(vm) do
    for frame <- [
          %CAN.Frame{id: 0x7FF, data: <<1, 2, 3>>},
          %CAN.Frame{id: 0x1FFFFFFF, data: <<0::64>>, extended?: true},
          %CAN.Frame{id: 42, data: <<>>, remote?: true}
        ] do
      packet = Scenarios.Device.rpc(vm, NervesGate.Linux.CAN, :encode_frame, [frame])
      assert byte_size(packet) == 16
      assert ^frame = Scenarios.Device.rpc(vm, NervesGate.Linux.CAN, :decode_frame, [packet])
    end

    assert nil ==
             Scenarios.Device.rpc(vm, NervesGate.Linux.CAN, :decode_frame, [<<0::128>> <> <<0>>])

    assert nil ==
             Scenarios.Device.rpc(vm, NervesGate.Linux.CAN, :decode_frame, [
               <<0x20000000::native-32, 0::96>>
             ])

    assert {:ok, %{listen_only: true}} =
             Scenarios.Device.rpc(vm, NervesGate.Buses.Policy, :configure, [
               "can0",
               %{"enabled" => true, "bitrate" => 250_000}
             ])

    assert {:ok, %{listen_only: false}} =
             Scenarios.Device.rpc(vm, NervesGate.Buses.Policy, :configure, [
               "can0",
               %{"enabled" => true, "bitrate" => 250_000, "listen_only" => false}
             ])
  end
end
