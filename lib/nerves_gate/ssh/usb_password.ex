defmodule NervesGate.SSH.USBPassword do
  @moduledoc false
  import Bitwise
  alias NervesGate.Linux.Netlink

  # OTP supplies the TCP peer, not a client-provided interface or address claim.
  # Never use a fixed address range: VintageNetDirect chooses a per-device /30.
  def check(user, password, peer, :undefined), do: check(user, password, peer, 0)

  def check(~c"root", ~c"nerves_gate", {peer, _port}, attempts),
    do: if(usb_peer?(ipv4(peer)), do: true, else: reject(attempts))

  def check(_, _, _, attempts), do: reject(attempts)

  # Preserve NervesSSH's three-attempt limit without logging credentials.
  defp reject(attempts) when is_integer(attempts) and attempts < 2, do: {false, attempts + 1}
  defp reject(_), do: :disconnect

  defp usb_peer?({a, b, c, d} = peer)
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 and
              rem(d, 4) in [1, 2] do
    with {:ok, addresses} <- :net.getifaddrs(:inet),
         {:ok, index} <- :net.if_name2index(~c"usb0") do
      Enum.any?(addresses, &usb_address?(&1, addresses, index, peer))
    else
      _ -> false
    end
  end

  defp usb_peer?(_), do: false

  defp usb_address?(
         %{
           name: ~c"usb0",
           flags: flags,
           addr: %{addr: local},
           netmask: %{addr: {255, 255, 255, 252}}
         },
         addresses,
         index,
         peer
       ) do
    :up in flags and :running in flags and local != peer and
      (integer(local) &&& 0xFFFFFFFC) == (integer(peer) &&& 0xFFFFFFFC) and
      independent?(addresses, peer) and direct_route?(index, local, peer)
  end

  defp usb_address?(_, _, _, _), do: false

  defp independent?(addresses, peer) do
    Enum.all?(addresses, fn
      %{name: ~c"usb0"} ->
        true

      %{addr: %{addr: address}, netmask: %{addr: mask}} ->
        (integer(address) &&& integer(mask)) != (integer(peer) &&& integer(mask))

      _ ->
        false
    end)
  end

  # Ask Linux which path it would use for this exact directly-connected peer.
  # Reject VPN/policy-route overrides and gateways; no shell command or cached
  # UI/network status participates in password authentication.
  defp direct_route?(index, local, peer) do
    body =
      <<2, 32, 32, 0, 0, 0, 0, 0, 0::native-32>> <>
        Netlink.attribute(1, <<integer(peer)::32>>) <>
        Netlink.attribute(2, <<integer(local)::32>>)

    case Netlink.request(26, 5, body) do
      {:ok, [{24, <<2, _::48, 1, _::32, attributes::binary>>}]} ->
        attributes = Netlink.attributes(attributes)
        attributes[4] == <<index::native-32>> and not Map.has_key?(attributes, 5)

      _ ->
        false
    end
  end

  defp ipv4({0, 0, 0, 0, 0, 65_535, high, low}),
    do: {high >>> 8, high &&& 255, low >>> 8, low &&& 255}

  defp ipv4(peer), do: peer
  defp integer({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d
end
