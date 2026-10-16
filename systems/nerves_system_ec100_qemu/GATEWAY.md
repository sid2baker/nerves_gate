# EC100-aligned QEMU test system

This is the real Nerves system used by the application's `x86_64` target, not a
host simulator. It lives under `systems` as development/test infrastructure,
not a second production hardware target. EC100 continues to use
the external checkout configured in the application's `mix.exs`; that checkout
is not copied or modified here.

The x86 source is based on
[`nerves-project/nerves_system_x86_64`](https://github.com/nerves-project/nerves_system_x86_64)
commit `5d755dba94fff478eac2bfd90ba91d2e0025d4eb` (1.34.2). Upstream licenses,
[changelog](UPSTREAM_CHANGELOG.md) and [hardware documentation](UPSTREAM_README.md)
are retained. `nerves_system_ec100_qemu` has its own version, starting at `0.1.0`.
Fingerprint-matched artifacts come from this project's GitHub Releases, never
from an unmodified upstream system.

## Alignment with EC100

Keep platform-independent settings aligned with `nerves_system_ec100`:

- Nerves 2, `nerves_system_br 1.34.5` (Buildroot 2026.05.3 / OTP 29.0.6),
  and the 15.3 toolchain family. All application targets share `mix.lock`;
  the release check also verifies its system dependencies match this package's lock.
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

The kernel fragment explicitly enables `NETFILTER_XTABLES_LEGACY`,
`IP_NF_IPTABLES_LEGACY` and `IP6_NF_IPTABLES_LEGACY`. Linux 6.17+ requires these
in addition to the filter/NAT/mangle selections. Without them, Kconfig drops NAT
before Buildroot's later iptables fixups enable legacy filtering; merely requesting
`IP_NF_NAT=y` in a fragment is not sufficient. Check the resolved kernel `.config`,
not just this fragment. The shared `firewall` scenario reads all three tables for
both address families on the actual guest, without enrollment or rule changes.

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

## Build and run

From the application root, use `mix setup`, then `mix dev`. Open `/tests` and
Start configured devices to build firmware and bootstrap QEMU. Setup downloads
this prebuilt system and installs the checksum-pinned x86 daemon; the launcher
builds firmware and boots an isolated disposable device. See the
[development guide](../../docs/development.md) for prerequisites and scenarios.
Do not use `fwup` against a physical disk for this test target.

The previous local variant was boot-tested with both device and workstation
Phoenix clients using the same Nerves backend. The renamed package's first hosted
build, published download and QEMU boot still need end-to-end validation. A/B
updates, recovery and complete kernel-feature parity also need qualification;
configuration tests alone do not prove them. See the
[development guide](../../docs/development.md) for the workflow and separate QEMU
management NIC.
