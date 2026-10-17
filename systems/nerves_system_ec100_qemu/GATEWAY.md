# EC100-aligned QEMU test system

`nerves_system_ec100_qemu` supplies the application's `x86_64` development system.
EC100 uses the release-tagged system dependency in `mix.exs`. Both run the same
gateway application.

The source is based on
[`nerves-project/nerves_system_x86_64`](https://github.com/nerves-project/nerves_system_x86_64)
commit `5d755dba94fff478eac2bfd90ba91d2e0025d4eb` (1.34.2). Upstream licenses,
[changelog](UPSTREAM_CHANGELOG.md) and [hardware documentation](UPSTREAM_README.md)
are retained. This package has its own `VERSION` and fingerprint-matched artifacts
in the project's GitHub Releases.

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
- fwup sets `nerves_fw_validated` instead of EC100's U-Boot `upgrade_available` and
  `bootcount`: `1` after a complete install, `0` after an upgrade until
  `Nerves.Runtime.StartupGuard` validates the booted slot. Both give the guard a
  known status. GRUB does not fall back automatically after a failed upgrade.
- No EC100 GPIO watchdog, USB provisioning gadget, LEDs, RS485 or CAN controller.
  The soft watchdog is also disabled, matching EC100's kernel policy.
- The fourth virtio NIC represents the provisioning link. The system's
  `erlinit --pre-run-exec` names it `usb0` before Erlang starts; the other three
  remain `eth0`, `eth1` and the private bench-management `eth2`.
- Board-ID reads the provisioned disk serial, and erlinit uses the full serial as
  the hostname. Plain VintageNetDirect configuration then derives the existing
  per-device USB subnet without an application-specific initialization hook.
  Disk discovery remains platform-specific.

## Build and run

From the application root:

```sh
mix setup
mix dev
```

Open **http://localhost:4000** and choose **Start devices**. Setup downloads the
prebuilt system; Start builds application firmware and bootstraps the configured
devices. Each `/devices/:id` page provides tests and a link to the gateway UI.
Use `mix dev.ui gateway_a` for gateway UI code reload.

Disks are disposable files. Never write this target to a physical disk. See
[development](../../docs/development.md) for configuration and scenarios, and
[coverage limits](../../docs/development.md#coverage-and-limits) for hardware qualification.
