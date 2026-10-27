defmodule NervesGate.Linux.CAN do
  @moduledoc "SocketCAN kernel observations. Does not open traffic sockets or implement protocol diagnostics."
  import Bitwise
  alias NervesGate.Linux.Netlink

  def snapshot(name) when name in ["can0", "can1"] do
    with {:ok, index} <- :net.if_name2index(String.to_charlist(name)),
         {:ok, links} <- Netlink.request(18, 5, <<0::32, index::native-signed-32, 0::64>>),
         {16,
          <<_::16, 280::native-16, _::native-32, flags::native-32, _::native-32, attrs::binary>>} <-
           List.first(links) do
      link = Netlink.attributes(attrs)
      info = link |> Map.get(18, <<>>) |> Netlink.attributes()
      data = info |> Map.get(2, <<>>) |> Netlink.attributes()

      %{
        name: name,
        present: true,
        kind: info |> Map.get(1, "") |> String.trim_trailing(<<0>>),
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
          kind: nil,
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
