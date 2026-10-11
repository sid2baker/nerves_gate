defmodule NervesGate.ModbusTest do
  use ExUnit.Case, async: true
  alias NervesGate.Buses.{Modbus, Policy}

  @params %{unit: 1, function: 3, address: 0, count: 1}

  test "known RTU vectors use big-endian registers and little-endian CRC" do
    assert Base.encode16(Modbus.request(@params)) == "010300000001840A"
    assert {:ok, [42]} = Modbus.response(Base.decode16!("010302002A399B"), @params)

    assert {:ok, [0, 65_535]} =
             Modbus.response(Modbus.checksum(<<247, 4, 4, 0::16, 65_535::16>>), %{
               unit: 247,
               function: 4,
               count: 2
             })
  end

  test "exact unit, function, byte count, frame size and CRC are required" do
    for packet <- [
          <<>>,
          <<1, 3>>,
          <<1, 3, 2, 0, 42, 0, 0>>,
          Modbus.checksum(<<2, 3, 2, 0, 42>>),
          Modbus.checksum(<<1, 4, 2, 0, 42>>),
          Modbus.checksum(<<1, 3, 4, 0, 42>>),
          Modbus.checksum(<<1, 3, 2, 0, 42, 99>>),
          Modbus.request(@params)
        ] do
      assert {:error, :modbus_response} = Modbus.response(packet, @params)
    end

    good = Modbus.checksum(<<1, 3, 2, 0, 42>>)
    assert {:error, :modbus_response} = Modbus.response(good <> good, @params)
    for size <- 0..6, do: refute(Modbus.complete?(binary_part(good, 0, size), @params))
    assert Modbus.complete?(good, @params)
  end

  test "exception frames must also match the selected unit and function" do
    packet = Modbus.checksum(<<1, 0x83, 2>>)
    assert Modbus.complete?(packet, @params)
    assert {:error, {:modbus_exception, 2}} = Modbus.response(packet, @params)
    assert {:error, :modbus_response} = Modbus.response(packet, %{@params | function: 4})
  end

  test "only qualified ports, enabled states and bounded read parameters normalize" do
    assert {:ok, %{enabled: true, listen_only: true, bitrate: 500_000}} =
             Policy.configure("can1", %{
               "enabled" => true,
               "bitrate" => 500_000,
               "listen_only" => false
             })

    assert {:ok, %{enabled: false}} = Policy.configure("ttyS4", %{"enabled" => false})

    assert {:ok, %{address: 65_535, count: 1, unit: 247, function: 4}} =
             Policy.modbus("ttyS4", %{
               "unit" => 247,
               "function" => 4,
               "address" => 65_535,
               "count" => 1,
               "authorized" => true
             })

    assert {:error, :modbus_parameters} = Policy.modbus("ttyS4", nil)

    for invalid <- [nil, [], %{}, true, "1bad", <<255>>] do
      assert {:error, _} = Policy.configure("can0", %{"enabled" => true, "bitrate" => invalid})
    end
  end
end
