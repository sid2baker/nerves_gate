#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIRMWARE=${NERVES_GATE_FIRMWARE:-"$ROOT/_build/x86_64_dev/nerves/images/nerves_gate.fw"}
STATE=${NERVES_GATE_QEMU_STATE:-"$ROOT/tmp/qemu"}
QEMU=${QEMU_SYSTEM_X86_64:-qemu-system-x86_64}
mkdir -p "$STATE"

if [[ -v NERVES_GATE_QEMU_NODES ]]; then
  read -r -a nodes <<<"$NERVES_GATE_QEMU_NODES"
else
  nodes=(M01 M02 M03)
fi

normalize_node() {
  local node=${1^^}
  [[ "$node" =~ ^M[0-9]{2,3}$ ]] || { echo "unknown node $1" >&2; exit 2; }
  echo "$node"
}

index_of() {
  local node digits
  node=$(normalize_node "$1")
  digits=${node#M}
  local index=$((10#$digits))
  ((index >= 1 && index <= 255)) || { echo "node index out of range: $node" >&2; exit 2; }
  echo "$index"
}

port_of() {
  echo $((4000 + $(index_of "$1")))
}

mac_of() {
  local family=$1 index=$2
  printf '52:54:00:47:%02x:%02x' "$family" "$index"
}

uuid_of() {
  local index=$1
  printf '5a3e0000-0000-4000-8000-%012d' "$index"
}

print_location() {
  local node=$1 state=$2 port
  port=$(port_of "$node")
  echo "$node $state; local setup/dashboard: http://${node,,}.localhost:$port/"
}

node_running() {
  local node=$1 pidfile pid
  pidfile="$STATE/$node.pid"
  test -f "$pidfile" || return 1
  pid=$(cat "$pidfile")
  kill -0 "$pid" 2>/dev/null || return 1
  test -r "/proc/$pid/cmdline" || return 1
  tr '\0' ' ' <"/proc/$pid/cmdline" | grep -Fq -- "$STATE/$node.img"
}

prepare_node() {
  local node disk
  node=$(normalize_node "$1")
  disk="$STATE/$node.img"
  test -f "$FIRMWARE" || { echo "Firmware not found: $FIRMWARE" >&2; exit 2; }

  if test ! -f "$disk"; then
    echo "Preparing $node persistent disk"
    truncate -s 4G "$disk"
    fwup -a -i "$FIRMWARE" -t complete -d "$disk" >/dev/null
  fi
}

start_node() {
  local node index port disk pidfile serial_socket qmp_socket uplink_mac setup_mac uuid accel=()
  node=$(normalize_node "$1")
  index=$(index_of "$node")
  port=$(port_of "$node")
  disk="$STATE/$node.img"
  pidfile="$STATE/$node.pid"
  serial_socket="$STATE/$node.serial.sock"
  qmp_socket="$STATE/$node.qmp.sock"
  uplink_mac=$(mac_of 1 "$index")
  setup_mac=$(mac_of 2 "$index")
  uuid=$(uuid_of "$index")
  prepare_node "$node"

  if node_running "$node"; then
    print_location "$node" "already running"
    return
  fi

  rm -f "$pidfile"

  test -r /dev/kvm && accel=(-enable-kvm)
  rm -f "$serial_socket" "$qmp_socket"

  "$QEMU" "${accel[@]}" -machine q35 -m 1024 -smp 2 -display none -monitor none \
    -qmp "unix:$qmp_socket,server=on,wait=off" \
    -chardev "socket,id=serial$index,path=$serial_socket,server=on,wait=off,logfile=$STATE/$node.serial.log,logappend=on" \
    -serial "chardev:serial$index" -no-reboot -uuid "$uuid" \
    -drive "file=$disk,if=virtio,format=raw" \
    -netdev "user,id=uplink$index" \
    -device "virtio-net-pci,id=uplink_device_$index,netdev=uplink$index,mac=$uplink_mac" \
    -netdev "user,id=setup$index,net=192.168.77.0/24,hostfwd=tcp:127.0.0.1:$port-192.168.77.1:80" \
    -device "virtio-net-pci,id=setup_device_$index,netdev=setup$index,mac=$setup_mac" \
    >"$STATE/$node.qemu.log" 2>&1 &

  echo $! >"$pidfile"
  print_location "$node" "started"
}

stop_node() {
  local node pidfile
  node=$(normalize_node "$1")
  pidfile="$STATE/$node.pid"

  if node_running "$node"; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    for _ in $(seq 1 50); do
      node_running "$node" || break
      sleep 0.1
    done

    if node_running "$node"; then
      kill -KILL "$(cat "$pidfile")" 2>/dev/null || true
    fi
  fi

  rm -f "$pidfile"

  rm -f "$STATE/$node.serial.sock" "$STATE/$node.qmp.sock"
  echo "$node stopped"
}

remove_node() {
  local node
  node=$(normalize_node "$1")
  stop_node "$node"
  rm -f "$STATE/$node.img" "$STATE/$node.serial.log" "$STATE/$node.qemu.log" \
    "$STATE/$node.serial.sock" "$STATE/$node.qmp.sock"
  echo "$node removed"
}

command=${1:-status}
target=${2:-all}
selected=("${nodes[@]}")
test "$target" = all || selected=("$(normalize_node "$target")")

case "$command" in
  prepare) for node in "${selected[@]}"; do prepare_node "$node"; done ;;
  start) for node in "${selected[@]}"; do start_node "$node"; done ;;
  stop) for node in "${selected[@]}"; do stop_node "$node"; done ;;
  restart) for node in "${selected[@]}"; do stop_node "$node"; start_node "$node"; done ;;
  reset)
    for node in "${selected[@]}"; do
      stop_node "$node"
      rm -f "$STATE/$node.img" "$STATE/$node.serial.log" "$STATE/$node.serial.sock" \
        "$STATE/$node.qmp.sock" "$STATE/$node.qemu.log"
      prepare_node "$node"
    done
    ;;
  remove) for node in "${selected[@]}"; do remove_node "$node"; done ;;
  status)
    for node in "${selected[@]}"; do
      pidfile="$STATE/$node.pid"
      if node_running "$node"; then
        print_location "$node" "running"
      else
        echo "$node stopped"
      fi
    done
    ;;
  *)
    echo "usage: $0 {prepare|start|stop|restart|reset|remove|status} [M01|M02|...|all]" >&2
    exit 2
    ;;
esac
