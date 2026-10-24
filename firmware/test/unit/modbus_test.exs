defmodule NervesGate.Buses.ModbusTest do
  use ExUnit.Case, async: true
  alias NervesGate.Buses.Modbus

  @request %{unit: 1, function: 3, address: 0, count: 2}

  test "encodes the standard read request with little-endian CRC" do
    assert Modbus.request(@request) == <<1, 3, 0, 0, 0, 2, 0xC4, 0x0B>>
  end

  test "decodes exact register counts and rejects corrupt or unrelated replies" do
    packet = Modbus.checksum(<<1, 3, 4, 0, 12, 255, 255>>)
    assert Modbus.response(packet, @request) == {:ok, [12, 65_535]}

    for payload <- [
          <<2, 3, 4, 0, 12, 255, 255>>,
          <<1, 4, 4, 0, 12, 255, 255>>,
          <<1, 3, 2, 0, 12>>,
          <<1, 3, 4, 0, 12, 255, 255, 0>>
        ] do
      assert Modbus.response(Modbus.checksum(payload), @request) ==
               {:error,
                %{
                  code: "modbus_response",
                  message:
                    "Invalid or unrelated Modbus response (address, function, length or CRC). No retry was sent."
                }}
    end

    assert Modbus.response(<<1, 3, 4, 0, 12, 255, 255, 0, 0>>, @request) ==
             {:error,
              %{
                code: "modbus_response",
                message:
                  "Invalid or unrelated Modbus response (address, function, length or CRC). No retry was sent."
              }}

    assert Modbus.response(<<>>, @request) ==
             {:error,
              %{
                code: "modbus_response",
                message:
                  "Invalid or unrelated Modbus response (address, function, length or CRC). No retry was sent."
              }}
  end

  test "bounds requests and recognizes fragmented replies and exceptions" do
    for patch <- [
          %{unit: 0},
          %{unit: 248},
          %{function: 6},
          %{count: 33},
          %{count: 0},
          %{address: 65_535, count: 2}
        ] do
      assert_raise FunctionClauseError, fn -> Modbus.request(Map.merge(@request, patch)) end
    end

    refute Modbus.complete?(<<1, 3, 4, 0>>, @request)
    assert Modbus.complete?(Modbus.checksum(<<1, 3, 4, 0, 0, 0, 0>>), @request)
    exception = Modbus.checksum(<<1, 0x83, 2>>)
    assert Modbus.complete?(exception, @request)
    assert Modbus.response(exception, @request) == {:error, {:modbus_exception, 2}}
  end
end
