defmodule NervesGate.Linux.Netlink do
  @moduledoc "Small bounded rtnetlink boundary for Linux neighbor and CAN observations/configuration."
  import Bitwise

  @kernel %{family: 16, addr: <<0::80>>}

  # Native sockaddr_nl, with the family supplied separately by OTP. A private
  # socket per request has no subscriptions and is closed if its owner dies.
  def request(type, flags, body) do
    with {:ok, socket} <- :socket.open(16, :raw, 0) do
      try do
        sequence = :erlang.unique_integer([:positive]) &&& 0xFFFFFFFF

        packet =
          <<byte_size(body) + 16::native-32, type::native-16, flags::native-16,
            sequence::native-32, 0::native-32, body::binary>>

        with :ok <- :socket.bind(socket, @kernel),
             :ok <- :socket.sendto(socket, packet, @kernel) do
          receive_reply(socket, sequence, [], 0, System.monotonic_time(:millisecond) + 1000)
        end
      after
        :socket.close(socket)
      end
    end
  end

  def attribute(type, value) do
    length = byte_size(value) + 4
    <<length::native-16, type::native-16, value::binary, 0::size(rem(4 - rem(length, 4), 4) * 8)>>
  end

  def attributes(binary), do: attributes(binary, %{})

  defp attributes(<<length::native-16, type::native-16, tail::binary>>, acc)
       when length >= 4 and byte_size(tail) >= length - 4 do
    <<value::binary-size(^length - 4), rest::binary>> = tail
    padding = rem(4 - rem(length, 4), 4)

    rest =
      if byte_size(rest) >= padding,
        do: binary_part(rest, padding, byte_size(rest) - padding),
        else: <<>>

    attributes(rest, Map.put(acc, type &&& 0x3FFF, value))
  end

  defp attributes(_, acc), do: acc

  defp receive_reply(socket, sequence, acc, bytes, deadline) when bytes < 262_144 do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    with {:ok, packet} <- :socket.recv(socket, 65_536, remaining) do
      case messages(packet, sequence, acc) do
        {:more, acc} -> receive_reply(socket, sequence, acc, bytes + byte_size(packet), deadline)
        result -> result
      end
    end
  end

  defp receive_reply(_, _, _, _, _), do: {:error, :observation_limit}

  defp messages(
         <<length::native-32, type::native-16, flags::native-16, sequence::native-32,
           _pid::native-32, tail::binary>>,
         sequence,
         acc
       )
       when length >= 16 and byte_size(tail) >= length - 16 do
    <<payload::binary-size(^length - 16), rest::binary>> = tail
    padding = rem(4 - rem(length, 4), 4)

    rest =
      if byte_size(rest) >= padding,
        do: binary_part(rest, padding, byte_size(rest) - padding),
        else: <<>>

    case {type, payload, flags &&& 0x10} do
      {_, _, interrupted} when interrupted != 0 -> {:error, :interrupted_dump}
      {2, <<0::native-signed-32, _::binary>>, _} -> {:ok, Enum.reverse(acc)}
      {2, <<error::native-signed-32, _::binary>>, _} -> {:error, {:netlink, -error}}
      {3, _, _} -> {:ok, Enum.reverse(acc)}
      _ -> messages(rest, sequence, [{type, payload} | acc])
    end
  end

  defp messages(<<>>, _, acc), do: {:more, acc}
  defp messages(_, _, _), do: {:error, :invalid_netlink_reply}
end
