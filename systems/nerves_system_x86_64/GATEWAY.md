# EC100-aligned QEMU test system

This is the real Nerves system used by the application's `x86_64` target, not a
host simulator. It lives under `systems` as development/test infrastructure,
not a second production hardware target. EC100 continues to use
the external checkout configured in the application's `mix.exs`; that checkout
is not copied or modified here.

The x86 source is based on
[`nerves-project/nerves_system_x86_64`](https://github.com/nerves-project/nerves_system_x86_64)
commit `5d755dba94fff478eac2bfd90ba91d2e0025d4eb` (1.34.2). Upstream licenses,
changelog and [hardware documentation](README.md) are retained. The local
`1.34.2-gate.1` variant uses fingerprinted local artifacts only, never an
unmodified upstream download.

## Alignment with EC100

Keep platform-independent settings aligned with `nerves_system_ec100`:

- Nerves 2, `nerves_system_br 1.34.5` (Buildroot 2026.05.3 / OTP 29.0.6),
  and the 15.3 toolchain family. All application targets share `mix.lock`.
- The standard Nerves skeleton, device table, BusyBox configuration, reproducible
  builds, and tar rootfs used by Nerves 2 firmware assembly.
- Bridge tools, iptables/ip6tables with the legacy firewall backend, CA
  certificates, libmnl/libnl and ext4 tools. No extra ODBC or smart-card stack.
- Built-in kernel drivers, dual-stack policy routing, bridging, TUN, conntrack,
  NAT, connection/packet marks and TCP MSS handling. Bridge netfilter is disabled:
  ordinary Layer-2 traffic must not traverse the IP firewall.
- A headless, wired kernel profile without audio, graphics, Wi-Fi or Bluetooth.
- Serial IEx through nbtty, clock initialization, crash dumps, shutdown reports,
  and a persistent `/root` (`/data` is the common skeleton's symlink to `/root`).

The application uses the same VintageNet, Tailscale and Linux equipment adapters
on both targets. Merely enabling kernel features does not configure routing,
NAT, DHCP or equipment ports. Missing EC100 peripherals remain unavailable;
this system does not simulate them.

## Deliberate platform differences

- x86_64/musl and virtio devices instead of ARMv7/glibc and Rockchip drivers.
  The upstream x86 toolchain is retained; QEMU cannot validate EC100 NIF ABI or
  physical I/O behavior. musl does not use glibc's generated locale archive.
- Linux 6.18.36 instead of EC100's RK3506 vendor kernel. Shared feature selections
  do not guarantee identical kernel behavior.
- GRUB/MBR and the upstream x86 A/B rootfs layout instead of EC100's U-Boot/GPT/FIT
  boot chain. Bootloader and data-partition offsets must not be copied from ARM.
- No EC100 GPIO watchdog, USB provisioning gadget, LEDs, RS485 or CAN controller.
  The soft watchdog is also disabled, matching EC100's kernel policy.
- x86 board-ID hostname and disk discovery remain platform-specific.

## Build from the application root

```sh
MIX_TARGET=x86_64 mix deps.get
MIX_TARGET=x86_64 mix nerves.artifact.build nerves_system_x86_64
# Supply a verified x86_64 tailscaled at rootfs_overlay/x86_64/usr/sbin/tailscaled.
# See the main README; building firmware does not download or replace it.
MIX_TARGET=x86_64 MIX_ENV=prod mix firmware
```

See the upstream [QEMU instructions](README.md#running-in-qemu) for making and
booting a disposable disk image. Do not use `fwup` against a physical disk for
this test target.

**Development build and QEMU boot verified**, including both device and workstation
Phoenix clients using the same Nerves backend. A/B updates, recovery and complete
kernel-feature parity still need qualification; configuration tests alone do not
prove them. See the [local Phoenix development guide](../../docs/development.md)
for the verified workflow and a separate QEMU management NIC.
