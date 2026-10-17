# Changelog

## Unreleased

## 0.2.0 - 2026-10-17

### Breaking changes

- The fourth virtio Ethernet interface is now exposed as `usb0` before Erlang starts. Applications must remove their own `eth3` rename and configure `usb0` directly.
- The hostname now uses the full board serial. With provisioned `qemu-N` serials, standard VintageNetDirect configuration preserves the simulator's existing USB recovery subnet without an application hostname override.

## 0.1.0 - 2026-10-14

### Added

- EC100-aligned x86_64 Nerves system for running the gateway in QEMU.
- Prebuilt system downloads for development without a local Buildroot build.

### Compatibility

- Linux 6.18.36, Erlang/OTP 29.0.6 and Buildroot 2026.05.3.
- Headless virtio hardware with dual-stack networking, bridging, TUN and legacy iptables/NAT support. EC100-specific peripherals are not emulated.
