defmodule Simulator.Network.Ethernet do
  @moduledoc false
  import Bitwise

  # Admission only. QEMU/libslirp implements ARP, DHCP, DNS and TCP/IP.
  # No IPv4 options (including source routing), VLANs, IPv6 or jumbo frames.
  def classify(frame, network) when byte_size(frame) in 14..1514 do
    case frame do
      <<_macs::binary-size(12), 0x0806::16, 1::16, 0x0800::16, 6, 4, op::16, _sender_mac::48,
        source::32, _target_mac::48, target::32, _::binary>>
      when op in [1, 2] ->
        if arp?(network, source, target), do: :local, else: :deny

      <<_macs::binary-size(12), 0x0800::16, 0x45, _tos, length::16, _id::16, fragment::16, ttl,
        protocol, _checksum::16, source::32, target::32, payload::binary>>
      when length >= 20 and length <= byte_size(payload) + 20 and ttl > 0 ->
        ipv4(
          network,
          source,
          target,
          protocol,
          fragment &&& 0x3FFF,
          binary_part(payload, 0, length - 20)
        )

      _ ->
        :deny
    end
  end

  def classify(_, _), do: :deny

  defp arp?(:internet, source, target),
    do: (source == 0 or internet_source?(source)) and target >>> 8 == 0x0A0002

  defp arp?(_, _, _), do: false

  # DHCP clients send from 0.0.0.0, or from their Internet lease when renewing.
  defp ipv4(:internet, 0, target, 17, 0, <<68::16, 67::16, _::binary>>), do: dhcp(target)

  defp ipv4(:internet, source, target, 17, 0, <<68::16, 67::16, _::binary>>)
       when source >>> 8 == 0x0A0002,
       do: dhcp(target)

  defp ipv4(:internet, source, target, protocol, fragment, payload) do
    cond do
      not internet_source?(source) -> :deny
      target == 0x0A000203 -> dns(protocol, fragment, payload)
      forbidden?(target) -> :deny
      protocol in [1, 6, 17] -> :uplink
      true -> :deny
    end
  end

  defp ipv4(_, _, _, _, _, _), do: :deny

  defp dns(protocol, 0, <<_source::16, 53::16, _::binary>>) when protocol in [6, 17],
    do: :uplink

  defp dns(_, _, _), do: :deny

  defp internet_source?(address),
    do: address >>> 8 == 0x0A0002 and (address &&& 255) not in [0, 2, 3, 255]

  # Reject virtual-host aliases, local/control networks and non-unicast IPs.
  # The DNS address is admitted above, solely for port 53. No gateway TCP/UDP
  # reaches libslirp's workstation-loopback mapping. Reachable LAN/tailnet
  # destinations outside these bench networks remain allowed, as before.
  defp dhcp(target),
    do: if(target in [0xFFFFFFFF, 0x0A0002FF, 0x0A000202], do: :local, else: :deny)

  defp forbidden?(address) do
    first = address >>> 24

    first in [0, 127] or first >= 224 or
      address >>> 8 == 0x0A0002 or
      (address >>> 16) in [0xAC1F, 0xA9FE]
  end
end
