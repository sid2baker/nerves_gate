defmodule IotrouterExpansion.ProtocolTest do
  use ExUnit.Case, async: true
  alias IotrouterExpansion.Protocol

  defp bytes(hex), do: Base.decode16!(hex, case: :mixed)

  test "stock command vectors and CRC scope/byte order" do
    assert Protocol.command_interval() == 25
    assert Protocol.crc("123456789") == 0x4B37
    assert Protocol.search(1) == bytes("aa010101e05055")
    assert Protocol.search(2) == bytes("aa010102a05155")
    assert Protocol.start(2) == bytes("aa210102a19b55")
    assert Protocol.configure(1) == bytes("aa112101" <> String.duplicate("00", 32) <> "a34f55")

    assert Protocol.write(2, [true | List.duplicate(false, 15)]) ==
             bytes("aa31210201" <> String.duplicate("00", 31) <> "b72655")
  end

  test "fragmented replies, noise, corruption and concatenated messages" do
    reply = bytes("aa020801010301100000005e3255")

    for n <- 0..(byte_size(reply) - 1),
        do: assert(Protocol.reply(binary_part(reply, 0, n)) == :more)

    assert {:ok, 2, payload, <<1, 2>>} = Protocol.reply(<<9, 0, 4>> <> reply <> <<1, 2>>)

    assert {:ok, %{address: 1, type: 1, version: 3, di: 16, do: 0}, false} =
             Protocol.card(2, payload)

    corrupt = bytes("aa02080101030110000000000055")
    assert {:ok, 2, ^payload, <<>>} = Protocol.reply(corrupt <> reply)
    assert :more = Protocol.reply(corrupt)
    assert {:ok, 3, last, <<>>} = Protocol.reply(bytes("aa03080202010100100000780555"))
    assert {:ok, %{address: 2, type: 2, do: 16}, true} = Protocol.card(3, last)
    assert :error = Protocol.card(4, last)
    assert Protocol.ack?(0x12, <<1, 0>>, Protocol.configure_func(), 1)
    refute Protocol.ack?(0x12, <<2, 0>>, Protocol.configure_func(), 1)
    refute Protocol.ack?(0x12, <<1, 1>>, Protocol.configure_func(), 1)
  end

  test "cyclic frames validate CRC, retain fragments and resynchronize" do
    data = :binary.copy(<<0>>, 32) <> <<1>> <> :binary.copy(<<0>>, 31)
    # Captured frame CRC is 0x8341 on the wire: 41 83.
    frame = data <> <<0x8341::little-16>>
    assert Protocol.crc(data) == 0x8341
    {[], fragment} = Protocol.cyclic(binary_part(frame, 0, 40), 2)
    assert {[slots], <<>>} = Protocol.cyclic(fragment <> binary_part(frame, 40, 26), 2)
    assert length(slots) == 2
    assert [true | _] = Protocol.channels(List.last(slots), 16)
    assert {[^slots, ^slots], <<7>>} = Protocol.cyclic(<<99>> <> frame <> frame <> <<7>>, 2)
  end
end
