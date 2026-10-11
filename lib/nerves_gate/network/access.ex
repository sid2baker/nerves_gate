defmodule NervesGate.Network.Access do
  @moduledoc "Identifies the independent USB management path from server-observed addresses."
  alias NervesGate.Config

  # The local address comes from the signed LiveView HTTP session; the peer comes
  # from the current WebSocket, never form parameters, Host or forwarded headers.
  # Require VintageNetDirect's /30 and fail closed on uncertain/overlapping paths.
  def usb?(%{usb: %{present: true, link: true, addresses: addresses}} = observed, %{
        local: local,
        peer: {a, b, c, d} = peer
      })
      when is_binary(local) and a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 and
             rem(d, 4) in [1, 2] do
    peer = to_string(:inet.ntoa(peer))

    Enum.any?(addresses, &match?(%{address: ^local, prefix_length: 30}, &1)) and peer != local and
      Config.overlap?(local, 30, peer, 32) and independent?(observed, local)
  end

  def usb?(_, _) do
    false
  end

  defp independent?(observed, local) do
    (Map.get(observed, :ports, []) ++ [Map.get(observed, :bridge, %{})])
    |> Enum.flat_map(&Map.get(&1, :addresses, []))
    |> Enum.all?(fn ip -> not Config.overlap?(local, 30, ip.address, ip.prefix_length) end)
  end
end
