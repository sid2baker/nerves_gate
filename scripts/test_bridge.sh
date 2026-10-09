#!/usr/bin/env bash
# Runs the REAL firmware adapter in disposable namespaces, never the host LAN.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ${1:-} != --isolated ]]; then
  export NERVES_GATE_HOST_NETNS=$(readlink /proc/self/ns/net)
  exec unshare --user --map-root-user --net --mount "$0" --isolated
fi
[[ -n ${NERVES_GATE_HOST_NETNS:-} && $(readlink /proc/self/ns/net) != "$NERVES_GATE_HOST_NETNS" ]]
[[ $(ip -o link show | wc -l) == 1 ]] # Fresh namespace, only loopback.
for command in ip brctl ifconfig udhcpc dnsmasq mix; do command -v "$command" >/dev/null; done
mount --make-rprivate /
mount -t tmpfs tmpfs /run
mount -t sysfs sysfs /sys
mkdir -p /run/netns /run/dnsmasq
ip link set lo up
ip netns add peer0
ip netns add peer1
ip link add eth0 type veth peer name lan0
ip link set lan0 netns peer0
ip link set eth0 up
ip -n peer0 link set lo up
ip -n peer0 link set lan0 up
ip -n peer0 addr add 10.45.0.2/24 dev lan0
# This is an EXISTING LAN's DHCP server, only in the isolated test peer.
ip netns exec peer0 dnsmasq --no-daemon --user=root --group=root --conf-file=/dev/null --port=0 --interface=lan0 --bind-interfaces --dhcp-range=10.45.0.50,10.45.0.55,255.255.255.0,1h --dhcp-leasefile=/run/dnsmasq/test.leases --pid-file=/run/dnsmasq.pid >/run/dnsmasq.log 2>&1 &
trap 'tail -30 /run/dnsmasq.log; kill $! 2>/dev/null || true' EXIT
# Do not pass the developer shell's large environment (or credentials) to DHCP.
env -i HOME="$HOME" PATH="$PATH" LANG="${LANG:-C.UTF-8}" MIX_HOME="${MIX_HOME:-$HOME/.mix}" MIX_ARCHIVES="${MIX_ARCHIVES:-${MIX_HOME:-$HOME/.mix}/archives}" NERVES_GATE_HOST_NETNS="$NERVES_GATE_HOST_NETNS" MIX_TARGET=host MIX_ENV=test mix do compile + run --no-start test/integration/bridge.exs
