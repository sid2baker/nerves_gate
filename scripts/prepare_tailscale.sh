#!/bin/sh
# Package the official static daemon; tailscale_ex uses LocalAPI, not the CLI.
set -eu

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 ec100|x86_64 OVERLAY_DIR CACHE_DIR" >&2
    exit 1
fi

version=1.102.3
case "$1" in
    ec100)
        arch=arm
        sha256=568dffd398fa70698de3671a05f078dc29fef62b1daf248ef1f45f82fc3dc75d
        ;;
    x86_64)
        arch=amd64
        sha256=36ddd9b51be57ffc2990cf76323cfa13643bfbb1b8a969f6183fa164741cdef5
        ;;
    *) echo "Unsupported Tailscale target: $1" >&2; exit 1 ;;
esac

overlay=$2
cache=$3
archive="tailscale_${version}_${arch}.tgz"
url="https://pkgs.tailscale.com/stable/$archive"

mkdir -p "$cache" "$overlay/usr/sbin" "$overlay/usr/share/nerves_gate"
work=$(mktemp -d "$cache/.tailscale.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

verify() {
    printf '%s  %s\n' "$sha256" "$1" | sha256sum --check --status
}

if [ ! -f "$cache/$archive" ]; then
    curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
        --connect-timeout 30 --max-time 300 --retry 2 "$url" --output "$work/$archive"
    if ! verify "$work/$archive"; then
        echo "Tailscale checksum mismatch: $archive" >&2
        exit 1
    fi
    mv "$work/$archive" "$cache/$archive"
fi

# Verify cached downloads too; never silently trust a previously extracted binary.
if ! verify "$cache/$archive"; then
    echo "Tailscale checksum mismatch: $cache/$archive (remove it and retry)" >&2
    exit 1
fi

tar -xOzf "$cache/$archive" "tailscale_${version}_${arch}/tailscaled" > "$work/tailscaled"
test -s "$work/tailscaled"
chmod 0755 "$work/tailscaled"
# Rename within the destination filesystem, so an interrupted copy is never installed.
install -m 0755 "$work/tailscaled" "$overlay/usr/sbin/.tailscaled.tmp"
mv "$overlay/usr/sbin/.tailscaled.tmp" "$overlay/usr/sbin/tailscaled"
printf 'version=%s\narchitecture=%s\narchive_sha256=%s\nsource=%s\n' \
    "$version" "$arch" "$sha256" "$url" > "$overlay/usr/share/nerves_gate/tailscale.txt"
printf 'Packaged tailscaled %s (%s) at %s/usr/sbin/tailscaled\n' "$version" "$arch" "$overlay"
