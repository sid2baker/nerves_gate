defmodule IotrouterExpansion.Protocol do
  @moduledoc """
  IOTRouter expansion-bus frames, reverse-engineered from the stock EM300 agent.

  Commands and replies are `0xAA func len payload crc16 0x55`, CRC-16/MODBUS over
  `func len payload`, little-endian. After Start, cards stream unframed cyclic
  data: 32 bytes per card in chain order followed by the CRC of those bytes.

  Only digital slots (one byte per channel) are interpreted. The meaning of the 32
  configuration bytes is unknown; like the stock agent, they are sent as zeros.
  """
  import Bitwise

  @search 0x01
  @configure 0x11
  @start 0x21
  @write 0x31
  @slot 32

  def slot_size, do: @slot

  @doc "Minimum discovery/configuration command interval in milliseconds, from stock captures."
  def command_interval, do: 25

  def search(address), do: frame(@search, <<address>>)
  def configure(address), do: frame(@configure, <<address, 0::size(@slot)-unit(8)>>)
  def start(last_address), do: frame(@start, <<last_address>>)

  @doc "A digital output card's complete state: one byte per channel, zero padded."
  def write(address, values) when length(values) <= @slot do
    bytes = for value <- values, into: <<>>, do: <<if(value, do: 1, else: 0)>>
    pad = @slot - length(values)
    frame(@write, <<address, bytes::binary, 0::size(pad)-unit(8)>>)
  end

  def frame(func, payload) do
    body = <<func, byte_size(payload), payload::binary>>
    <<0xAA, body::binary, crc(body)::little-16, 0x55>>
  end

  @doc """
  The first valid reply in `buffer` as `{:ok, func, payload, rest}`, or `:more`
  until one is complete. Bytes that cannot start a valid reply are skipped.
  """
  def reply(<<0xAA, func, len, rest::binary>> = buffer) do
    case rest do
      <<payload::binary-size(^len), crc::little-16, 0x55, tail::binary>> ->
        if crc == crc(<<func, len, payload::binary>>),
          do: {:ok, func, payload, tail},
          else: skip(buffer)

      _ when byte_size(rest) < len + 3 ->
        :more

      _ ->
        skip(buffer)
    end
  end

  def reply(<<0xAA>>), do: :more
  def reply(<<0xAA, _>>), do: :more
  def reply(<<_, rest::binary>>), do: reply(rest)
  def reply(<<>>), do: :more

  defp skip(<<_, rest::binary>>), do: reply(rest)

  @doc "A search reply as `{:ok, card, last?}`."
  def card(func, <<address, type, version, 1, di, outputs, ai, ao>>) when func in [0x02, 0x03] do
    card = %{address: address, type: type, version: version, di: di, do: outputs, ai: ai, ao: ao}
    {:ok, card, func == 0x03}
  end

  def card(_, _), do: :error

  @doc "Whether `func`/`payload` acknowledge `request` for `address`."
  def ack?(func, payload, request, address), do: func == request + 1 and payload == <<address, 0>>

  def configure_func, do: @configure
  def start_func, do: @start

  @doc """
  Split a cyclic stream for `count` cards into CRC-valid frames, skipping bytes
  until a CRC matches. Returns `{frames, rest}`; each frame is a list of slots.
  """
  def cyclic(buffer, count, frames \\ [])

  def cyclic(buffer, count, frames)
      when is_integer(count) and count > 0 and byte_size(buffer) >= count * @slot + 2 do
    size = count * @slot
    <<data::binary-size(^size), crc::little-16, rest::binary>> = buffer

    if crc == crc(data),
      do: cyclic(rest, count, [for(<<slot::binary-size(@slot) <- data>>, do: slot) | frames]),
      else: cyclic(binary_part(buffer, 1, byte_size(buffer) - 1), count, frames)
  end

  def cyclic(buffer, count, frames) when is_integer(count) and count > 0,
    do: {Enum.reverse(frames), buffer}

  @doc "Digital channel values of a slot (one byte per channel)."
  def channels(slot, count) do
    for <<byte <- binary_part(slot, 0, count)>> do
      case byte do
        0 -> false
        1 -> true
        _ -> raise ArgumentError, "Unsupported digital channel encoding"
      end
    end
  end

  def crc(data) do
    for <<byte <- data>>, reduce: 0xFFFF do
      acc ->
        Enum.reduce(1..8, bxor(acc, byte), fn _, crc ->
          if band(crc, 1) == 1, do: bxor(crc >>> 1, 0xA001), else: crc >>> 1
        end)
    end
  end
end
