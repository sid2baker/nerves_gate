#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIRMWARE=${NERVES_GATE_FIRMWARE:-"$ROOT/_build/x86_64_dev/nerves/images/nerves_gate.fw"}
STATE=${NERVES_GATE_QEMU_STATE:-"$ROOT/tmp/qemu"}
QEMU=${QEMU_SYSTEM_X86_64:-qemu-system-x86_64}
mkdir -p "$STATE"

nodes=(M01 M02 M03)
ports=(4001 4002 4003)
macs=(52:54:00:47:01:01 52:54:00:47:01:02 52:54:00:47:01:03)
uuids=(5a3e0000-0000-4000-8000-000000000001 5a3e0000-0000-4000-8000-000000000002 5a3e0000-0000-4000-8000-000000000003)

index_of() {
  case "$1" in M01) echo 0;; M02) echo 1;; M03) echo 2;; *) echo "unknown node $1" >&2; exit 2;; esac
}

print_location() {
  local node=$1 state=$2 i tailnet_file="$STATE/$1.tailnet-ip"
  i=$(index_of "$node")

  if test -s "$tailnet_file"; then
    echo "$node $state; dashboard (tailnet only): http://$(tr -d '\r\n' <"$tailnet_file")/"
  else
    echo "$node $state; setup forward: http://127.0.0.1:${ports[$i]}/ (closes when commissioning completes)"
  fi
}

prepare_node() {
  local node=$1 disk="$STATE/$1.img"
  test -f "$FIRMWARE" || { echo "Firmware not found: $FIRMWARE" >&2; exit 2; }
  if test ! -f "$disk"; then
    echo "Preparing $node persistent disk"
    truncate -s 4G "$disk"
    fwup -a -i "$FIRMWARE" -t complete -d "$disk" >/dev/null
  fi
}

start_node() {
  local node=$1 i port disk pidfile accel=()
  i=$(index_of "$node")
  port=${ports[$i]}
  disk="$STATE/$node.img"
  pidfile="$STATE/$node.pid"
  prepare_node "$node"

  if test -f "$pidfile" && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    print_location "$node" "already running"
    return
  fi

  test -r /dev/kvm && accel=(-enable-kvm)

  "$QEMU" "${accel[@]}" -machine q35 -m 1024 -smp 2 -display none -monitor none \
    -serial "file:$STATE/$node.serial.log" -no-reboot -uuid "${uuids[$i]}" \
    -drive "file=$disk,if=virtio,format=raw" \
    -netdev "user,id=uplink$i" \
    -device "virtio-net-pci,netdev=uplink$i,mac=${macs[$i]}" \
    -netdev "user,id=setup$i,net=192.168.77.0/24,hostfwd=tcp:127.0.0.1:$port-192.168.77.1:80" \
    -device "virtio-net-pci,netdev=setup$i,mac=52:54:00:47:02:0$((i + 1))" \
    >"$STATE/$node.qemu.log" 2>&1 &

  echo $! >"$pidfile"
  print_location "$node" "started"
}

stop_node() {
  local node=$1 pidfile="$STATE/$1.pid"
  if test -f "$pidfile"; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$(cat "$pidfile")" 2>/dev/null || break
      sleep 0.1
    done
    rm -f "$pidfile"
  fi
  echo "$node stopped"
}

command=${1:-status}
target=${2:-all}
selected=("${nodes[@]}")
test "$target" = all || selected=("$target")

case "$command" in
  prepare) for node in "${selected[@]}"; do prepare_node "$node"; done ;;
  start) for node in "${selected[@]}"; do start_node "$node"; done ;;
  stop) for node in "${selected[@]}"; do stop_node "$node"; done ;;
  restart) for node in "${selected[@]}"; do stop_node "$node"; start_node "$node"; done ;;
  reset)
    for node in "${selected[@]}"; do
      stop_node "$node"
      rm -f "$STATE/$node.img" "$STATE/$node.serial.log" "$STATE/$node.qemu.log" \
        "$STATE/$node.tailnet-ip"
      prepare_node "$node"
    done
    ;;
  status)
    for node in "${selected[@]}"; do
      pidfile="$STATE/$node.pid"
      if test -f "$pidfile" && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        print_location "$node" "running"
      else
        echo "$node stopped"
      fi
    done
    ;;
  *) echo "usage: $0 {prepare|start|stop|restart|reset|status} [M01|M02|M03|all]" >&2; exit 2 ;;
esac
