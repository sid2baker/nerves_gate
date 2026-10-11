#!/usr/bin/env bash
# Native packet/netlink checks in a fresh namespace. Never probe the host LAN.
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
mount -t sysfs sysfs /sys
mkdir -p /run/netns
ip link set lo up
ip netns add machine
ip link add eth1 type veth peer name machine0
ip link set machine0 netns machine
ip addr add 192.168.50.2/24 dev eth1
ip link set eth1 up
ip -n machine link set lo up
ip -n machine addr add 192.168.50.10/24 dev machine0
ip -n machine link set machine0 up
if ip link add can0 type vcan 2>/dev/null; then
  ip link set can0 up
  export NERVES_GATE_TEST_CAN=1
fi
exec env -i HOME="$HOME" PATH="$PATH" LANG="${LANG:-C.UTF-8}" \
  MIX_HOME="${MIX_HOME:-$HOME/.mix}" MIX_ARCHIVES="${MIX_ARCHIVES:-${MIX_HOME:-$HOME/.mix}/archives}" \
  NERVES_GATE_HOST_NETNS="$NERVES_GATE_HOST_NETNS" NERVES_GATE_TEST_CAN="${NERVES_GATE_TEST_CAN:-0}" \
  MIX_TARGET=host MIX_ENV=test mix run --no-start test/integration/equipment_test.exs --isolated
