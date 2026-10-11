defmodule NervesGate.Linux.CAN do
  @moduledoc "SocketCAN observations, explicit link configuration, and bounded receive-only captures."
  import Bitwise
  alias NervesGate.Linux.Netlink

  def snapshot(name) when name in ["can0", "can1"] do
    with {:ok, index} <- :net.if_name2index(String.to_charlist(name)),
         {:ok, links} <- Netlink.request(18, 5, info(index, 0, 0)),
         {16, <<_::binary-size(8), flags::native-32, _::native-32, attrs::binary>>} <-
           List.first(links) do
      link = Netlink.attributes(attrs)

      data =
        link
        |> Map.get(18, <<>>)
        |> Netlink.attributes()
        |> Map.get(2, <<>>)
        |> Netlink.attributes()

      %{
        name: name,
        present: true,
        up: (flags &&& 1) != 0,
        bitrate: uint32(data[1]),
        state: state(uint32(data[4])),
        listen_only: listen_only(data[5]),
        errors: errors(data[8]),
        rx_packets: counter(name, "rx_packets"),
        tx_packets: counter(name, "tx_packets")
      }
    else
      _ ->
        %{
          name: name,
          present: false,
          up: false,
          state: "undetected",
          bitrate: nil,
          listen_only: nil,
          errors: nil,
          rx_packets: nil,
          tx_packets: nil
        }
    end
  end

  def configure(name, %{enabled: enabled, bitrate: bitrate, listen_only: listen_only})
      when name in ["can0", "can1"] do
    with {:ok, index} <- :net.if_name2index(String.to_charlist(name)),
         {:ok, _} <- Netlink.request(16, 5, info(index, 0, 1)) do
      if enabled do
        enable(index, bitrate, listen_only)
      else
        :ok
      end
    end
  end

  defp enable(index, bitrate, listen_only) do
    timing = Netlink.attribute(1, <<bitrate::native-32, 0::224>>)

    mode =
      Netlink.attribute(
        5,
        <<2::native-32,
          if listen_only do
            2
          else
            0
          end::native-32>>
      )

    attrs =
      Netlink.attribute(
        0x8012,
        Netlink.attribute(1, "can\0") <> Netlink.attribute(0x8002, timing <> mode)
      )

    with {:ok, _} <- Netlink.request(16, 5, info(index, 0, 0) <> attrs),
         {:ok, _} <- Netlink.request(16, 5, info(index, 1, 1)) do
      :ok
    end
  end

  def capture(name) when name in ["can0", "can1"] do
    with {:ok, index} <- :net.if_name2index(String.to_charlist(name)),
         {:ok, socket} <- :socket.open(29, :raw, 1) do
      try do
        with :ok <- :socket.bind(socket, %{family: 29, addr: <<0::16, index::native-32, 0::64>>}) do
          collect(socket, [], System.monotonic_time(:millisecond) + 5000)
        end
      after
        :socket.close(socket)
      end
    end
  end

  def decode(<<id::native-32, size, _::24, data::binary-size(8)>>) when size <= 8 do
    %{
      id: Integer.to_string(id &&& 0x1FFFFFFF, 16),
      extended: (id &&& 0x80000000) != 0,
      remote: (id &&& 0x40000000) != 0,
      error: (id &&& 0x20000000) != 0,
      data: Base.encode16(binary_part(data, 0, size)),
      received_at: System.system_time(:millisecond)
    }
  end

  def decode(_), do: nil

  defp collect(socket, frames, deadline) do
    collect(socket, frames, deadline, 200)
  end

  defp collect(_, frames, _, 0) do
    {:ok, Enum.reverse(frames)}
  end

  defp collect(socket, frames, deadline, remaining) do
    case :socket.recv(socket, 16, max(deadline - System.monotonic_time(:millisecond), 0)) do
      {:ok, packet} ->
        {frames, remaining} =
          case decode(packet) do
            nil -> {frames, remaining}
            frame -> {[frame | frames], remaining - 1}
          end

        if System.monotonic_time(:millisecond) < deadline do
          collect(socket, frames, deadline, remaining)
        else
          {:ok, Enum.reverse(frames)}
        end

      {:error, :timeout} ->
        {:ok, Enum.reverse(frames)}

      error ->
        error
    end
  end

  defp info(index, flags, change),
    do: <<0::8, 0::8, 0::native-16, index::native-signed-32, flags::native-32, change::native-32>>

  defp uint32(<<value::native-32, _::binary>>), do: value
  defp uint32(_), do: nil
  defp listen_only(<<_mask::native-32, flags::native-32>>), do: (flags &&& 2) != 0
  defp listen_only(_), do: nil
  defp errors(<<tx::native-16, rx::native-16>>), do: %{tx: tx, rx: rx}
  defp errors(_), do: nil

  defp state(number),
    do:
      Map.get(
        %{
          0 => "error active",
          1 => "error warning",
          2 => "error passive",
          3 => "bus off",
          4 => "stopped",
          5 => "sleeping"
        },
        number,
        "unknown"
      )

  defp counter(name, counter) do
    with {:ok, value} <- File.read("/sys/class/net/#{name}/statistics/#{counter}"),
         {number, _} <- Integer.parse(value),
         do: number,
         else: (_ -> nil)
  end
end
