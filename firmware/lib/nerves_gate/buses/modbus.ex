defmodule NervesGate.Buses.Modbus do
  @moduledoc "Modbus RTU functions 3/4 only, raw zero-based registers, CRC-checked exact responses."
  import Bitwise

  def request(%{unit: unit, function: function, address: address, count: count})
      when unit in 1..247 and function in [3, 4] and address in 0..65_535 and
             count in 1..32 and address + count <= 65_536 do
    checksum(<<unit, function, address::16, count::16>>)
  end

  def response(packet, %{unit: unit, function: function, count: count}) do
    with true <- byte_size(packet) >= 5,
         size = byte_size(packet) - 2,
         <<payload::binary-size(^size), received::little-16>> <- packet,
         true <- crc(payload) == received do
      decode(payload, unit, function, count)
    else
      _ -> {:error, :modbus_response}
    end
  end

  def complete?(<<_, function, _::binary>> = packet, %{count: count}) do
    expected = if (function &&& 0x80) != 0, do: 5, else: 5 + 2 * count
    byte_size(packet) >= expected
  end

  def complete?(_, _), do: false

  def checksum(payload), do: <<payload::binary, crc(payload)::little-16>>

  defp decode(<<unit, function, bytes, registers::binary>>, unit, function, count)
       when bytes == count * 2 and byte_size(registers) == bytes do
    {:ok, for(<<value::16 <- registers>>, do: value)}
  end

  defp decode(<<unit, exception, code>>, unit, function, _) when exception == function + 128,
    do: {:error, {:modbus_exception, code}}

  defp decode(_, _, _, _), do: {:error, :modbus_response}

  defp crc_bit(_, value) when (value &&& 1) == 1, do: bxor(value >>> 1, 0xA001)
  defp crc_bit(_, value), do: value >>> 1

  defp crc(payload) do
    for <<byte <- payload>>, reduce: 0xFFFF do
      crc ->
        Enum.reduce(1..8, bxor(crc, byte), &crc_bit/2)
    end
  end
end
