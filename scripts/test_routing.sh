#!/usr/bin/env bash
# Firmware routing prerequisites only, in a fresh namespace. No VPN enrollment.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ${1:-} != --isolated ]]; then
  export NERVES_GATE_HOST_NETNS=$(readlink /proc/self/ns/net)
  exec unshare --user --map-root-user --net --mount "$0" --isolated
fi
[[ -n ${NERVES_GATE_HOST_NETNS:-} && $(readlink /proc/self/ns/net) != "$NERVES_GATE_HOST_NETNS" ]]
[[ $(ip -o link show | wc -l) == 1 ]]
mount --make-rprivate /
mount -t tmpfs tmpfs /run
mkdir -p /run/netns
ip link set lo up
for name in client equipment; do
  ip netns add "$name"
  ip link add "$name" type veth peer name peer0
  ip link set peer0 netns "$name"
  ip link set "$name" up
  ip -n "$name" link set lo up
  ip -n "$name" link set peer0 up
done
ip addr add 192.168.80.2/24 dev client
ip addr add 192.168.50.2/24 dev equipment
ip -n client addr add 192.168.80.10/24 dev peer0
ip -n equipment addr add 192.168.50.10/24 dev peer0
ip -n client route add 192.168.50.0/24 via 192.168.80.2
ip -n equipment route add 192.168.80.0/24 via 192.168.50.2

setup=rootfs_overlay/common/usr/sbin/nerves-gate-routing
"$setup"
[[ $(</proc/sys/net/ipv4/ip_forward) == 1 ]]
iptables -S FORWARD | grep -qx -- '-P FORWARD DROP'
# Local recovery endpoints still work, but ordinary LAN-to-LAN routing does not.
ip netns exec client ping -n -c 1 -W 1 192.168.80.2 >/dev/null
ip netns exec equipment ping -n -c 1 -W 1 192.168.50.2 >/dev/null
if ip netns exec client ping -n -c 1 -W 1 192.168.50.10 >/dev/null; then
  echo "Unexpected unrestricted LAN forwarding" >&2
  exit 1
fi

# The default policy permits explicit allow rules (owned by Tailscale on firmware).
# This is NOT a test of enrollment, tailnet ACLs or Tailscale's own rules/NAT.
iptables -A FORWARD -i client -o equipment -j ACCEPT
iptables -A FORWARD -i equipment -o client -j ACCEPT
ip netns exec client ping -n -c 1 -W 1 192.168.50.10 >/dev/null
"$setup"
iptables -C FORWARD -i client -o equipment -j ACCEPT

# Missing firewall support must leave forwarding off without preventing boot.
stubs=$(mktemp -d)
trap 'rm -rf "$stubs"' EXIT
printf '#!/bin/sh\nexit 1\n' > "$stubs/iptables"
chmod +x "$stubs/iptables"
PATH="$stubs:$PATH" "$setup"
[[ $(</proc/sys/net/ipv4/ip_forward) == 0 ]]
echo "Verified isolated IPv4 forwarding, default deny, local access and fail-closed boot setup"
