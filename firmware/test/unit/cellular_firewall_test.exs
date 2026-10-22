defmodule NervesGate.Network.CellularFirewallTest do
  use ExUnit.Case, async: true
  alias NervesGate.Network.Vintage

  test "both families deny unsolicited cellular input, allowing replies and IPv4 DHCP first" do
    replies = [
      "-i",
      "wwan+",
      "-m",
      "conntrack",
      "--ctstate",
      "ESTABLISHED,RELATED",
      "-j",
      "ACCEPT"
    ]

    dhcp = ["-i", "wwan+", "-p", "udp", "--sport", "67", "--dport", "68", "-j", "ACCEPT"]
    drop = ["-i", "wwan+", "-j", "DROP"]

    assert Vintage.cellular_input_rules("iptables") == [replies, dhcp, drop]
    assert Vintage.cellular_input_rules("ip6tables") == [replies, drop]
  end
end
