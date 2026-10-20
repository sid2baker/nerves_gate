# nerves_system_ec100

[Nerves](https://nerves-project.org/) system for the **IOTRouter EC100**, based on
the Rockchip RK3506J (ARM Cortex-A7).

- Source-built U-Boot and Linux with pinned Rockchip DDR, SPL, and secure firmware
- A/B firmware updates with application validation and boot-count rollback
- Shared ext4 application storage at `/data` (`/root`)
- Ethernet, eMMC, and a **115200 8N1** serial console (no flow control)

## Build

This system requires Nerves 2 (currently `2.0.0-pre.3`). For an existing application,
update its Nerves dependency, remove `:shoehorn`, and replace
`&Nerves.Release.init/1` with `&Nerves.init_release/1` in its release steps.

Add this system to your Nerves application's dependencies and target configuration:

```elixir
{:nerves_system_ec100,
 path: "../nerves_system_ec100",
 runtime: false,
 targets: [:ec100]}
```

Adjust the path for your checkout. From the application directory:

```sh
mix deps.get
MIX_TARGET=ec100 mix nerves.artifact.build nerves_system_ec100
MIX_TARGET=ec100 mix firmware
```

Nerves 2 does not automatically build custom systems. The artifact build requires
a working Docker or Podman installation; rerun it after changing this system.
Prebuilt artifacts are downloaded as needed by `mix firmware`, not `mix deps.get`.
For the first build after upgrading from Nerves 1, use a fresh system checkout:
the current prerelease copies old `.nerves/` and Buildroot caches into its container
workspace, which can exhaust disk space or leave broken host-path symlinks.

The build produces application firmware (`.fw`) and separate factory boot images.
It does not flash the board. Source pins are listed in [SOURCES.md](SOURCES.md);
boot-image details are in [bootstrap/README.md](bootstrap/README.md).

## Prebuilt systems and releases

The [System artifact workflow](.github/workflows/artifacts.yml) builds with Nerves 2
from a clean checkout. Run it manually for an untagged development build; its
`ec100-system` Actions artifact contains the system tarball, corresponding-source
tarball, and `SHA256SUMS` and is retained for 14 days. It does not contain application firmware (`.fw`).

Pushing a version tag builds the system and creates a **draft** GitHub release.
Nothing publishes automatically. Release tarballs keep Nerves' generated name,
including the source fingerprint. Nerves looks for them under `v<VERSION>`; do not
rename a tarball or move a published tag.

Once a release has been published, an application can replace its local path
with a Git dependency pinned to that tag (Hex publication is not required):

```elixir
{:nerves_system_ec100,
 github: "sid2baker/nerves_system_ec100",
 tag: "v<release-version>",
 runtime: false,
 targets: [:ec100]}
```

Then run `mix deps.get` and `MIX_TARGET=ec100 mix firmware`. Nerves downloads the
matching system artifact. Keep the path dependency and explicit artifact build
when developing the system itself.

### Maintainer release checklist

The workflow runs Buildroot's `make legal-info`, adds the external toolchain's
sources and notices, and includes the matching Buildroot and EC100 build recipes.
See [SOURCES.md](SOURCES.md#release-source-archive) for the archive layout and local
command. When updating components, review the collected manifests, warnings, and
notices, and update the pinned toolchain source list if needed. Always distribute
the source tarball alongside the system tarball.

1. Keep a `-dev` version during development. For a release, choose an unused
   version such as `0.2.0`, update `VERSION`, and move the relevant
   [changelog](CHANGELOG.md) entries into `## 0.2.0 - YYYY-MM-DD`, leaving
   `Unreleased` at the top. Use `0.2.0-rc.1` instead when a prerelease is intended.
   Release notes are copied from that section; missing, empty, or duplicate
   sections fail before the build.
2. Commit the final sources and push the matching `v0.2.0` tag. The workflow
   refuses tags that disagree with `VERSION` and refuses `-dev` releases. It never
   overwrites an existing release. Only the release job has `contents: write`;
   no personal token or Hex credentials are needed.
3. Verify `SHA256SUMS`, download the draft assets with maintainer credentials,
   and test the exact artifact in a clean application environment. Supply a
   maintainer token through `GH_TOKEN` or the GitHub CLI: Nerves 2 can fall back
   to the authenticated API for draft assets. Do not edit `mix.exs` to test the
   download, since that changes the fingerprint. Public downloads only work
   after publication. Test firmware built from that artifact on EC100,
   including boot, networking, factory recovery, and A/B update/rollback.
4. Review the draft's title (exactly the tag), changelog notes, assets, and
   prerelease flag before publishing. After publication, verify an unauthenticated
   download and a fresh application build. Do not promote untested binaries.

The workflow deliberately does not reuse host `deps/`, `.nerves/`, or Buildroot
workspaces: Nerves `2.0.0-pre.3` can copy broken host symlinks into containers.
Dependencies are locked, but the prerelease's default container uses a mutable
base image, and the vendor loader tool embeds a timestamp. Builds are not claimed
to be bit-for-bit reproducible.

## Factory installation

**Factory flashing replaces the boot chain, partition layout, and application data.**
Use a stable power supply and keep a recovery backup. Installation is not
power-loss atomic.

Requirements: `rkdeveloptool`, `fwup`, Elixir/OTP, and enough space for a full eMMC
backup (about 3.8 GB) plus staging files. Connect exactly one EC100 in MASKROM mode.
From the application directory:

```sh
MIX_TARGET=ec100 mix ec100.flash
```

The task builds firmware, asks for confirmation, backs up the eMMC user area to
`ec100-backups/`, installs the GPT, boot images, and slot A, verifies writes, and
resets the board. It does not write the eMMC boot0/boot1 hardware partitions.

USB commands use `sudo -n` by default; authenticate beforehand or use `--no-sudo`
with suitable USB permissions. Other options are `--no-reset`, `--yes`, and
`--no-backup`. Skipping the backup removes the ability to restore the previous
firmware and data from that run. Readback verification always runs.

## OTA updates

The application must provide SSH firmware upload support and an authorized key.
From the application directory:

```sh
MIX_TARGET=ec100 mix firmware
MIX_TARGET=ec100 mix firmware.gen.script
./upload.sh <board-address>
```

OTA writes the inactive kernel/rootfs slot and selects it for the next boot. It
preserves the bootloader, partition table, and shared data. Provision the GPT layout
with factory installation; OTA does not repartition the eMMC. Configure the
application's upload success callback to reboot, or reboot after a successful upload.

Check the running trial in IEx:

```elixir
Nerves.Runtime.KV.get_all_active()
Nerves.Runtime.KV.get_all() |> Map.take(["nerves_fw_active", "upgrade_available", "bootcount"])
```

Enable [StartupGuard in the application](#application-setup) to validate firmware
automatically after the expected OTP applications start. For an application
configured for manual validation, check its health and then confirm it:

```elixir
Nerves.Runtime.validate_firmware()
```

Rebooting does not alternate slots. With `bootlimit=3`, an unvalidated trial gets
three boot attempts; the fourth rolls back. Validation keeps the selected slot
and clears the trial flag and counter. Keep data migrations rollback-compatible.

## Storage

| Region | Start | Size |
| --- | ---: | ---: |
| Protective MBR and primary GPT | 0 | 17 KiB |
| DDR/SPL loader | 32 KiB | Below 8 MiB |
| U-Boot/TEE FIT | 8 MiB | Up to 4 MiB |
| Environment A / B | 12 / 12.125 MiB | 128 KiB each |
| Kernel FIT A / B | 16 / 48 MiB | 32 MiB each |
| Rootfs A (`mmcblk0p1`) | 80 MiB | 256 MiB |
| Rootfs B (`mmcblk0p2`) | 336 MiB | 256 MiB |
| Data (`mmcblk0p3`) | 592 MiB | Remaining space before backup GPT |
| Backup GPT | Final 33 sectors | 16.5 KiB |

The eMMC uses GPT with three partitions named `rootfs-a`, `rootfs-b`, and `data`.
Root filesystems are read-only SquashFS. Nerves initializes the shared ext4 data
partition on first use and mounts it at `/root`; `/data` is an alias. Raw FIT slots
are outside the GPT partitions. The kernel supports both gzip and XZ SquashFS.

## Factory reset (application data only)

Use the standard Nerves operation, after stopping application data writers:

```elixir
Nerves.Runtime.FwupOps.factory_reset()
```

Like the [Raspberry Pi](https://github.com/nerves-project/nerves_system_rpi4/blob/main/fwup-ops.conf)
and [BeagleBone](https://github.com/nerves-project/nerves_system_bbb/blob/main/fwup-ops.conf)
systems, this invalidates the first 128 KiB of the data filesystem. The runtime
immediately reboots, and `Nerves.Runtime.Init` reformats the **actual partition**
on the next boot. No fixed 512 MiB trim or custom formatter is needed. This is a
logical reset, **not secure erasure**; old data blocks may remain recoverable.

The application owns the reset procedure:

1. Prevent firmware updates and new writes; stop databases, logging, and other
   users of `/data`/`/root`, including shell history. Leave any working directory
   on that filesystem.
2. Unmount `/root` normally (and any other mounts of the same partition). Abort
   on failure; do not use lazy/forced unmount. The fwup task itself does **not**
   enforce this, and requiring the whole destination disk to be unmounted would
   also reject the running root filesystem.
3. Call `factory_reset()` with its default immediate reboot. Do not use
   `reboot: false` or perform a graceful shutdown after invalidation. If the call
   fails, treat reset as incomplete; do not resume normal data writes.
4. After reboot, verify `/root` is mounted read-write as ext4 before starting
   data-dependent services. Runtime format/mount failures must not be treated as
   a successful reset by the application.

The task does not write GPT, firmware slots, U-Boot, its environment, or hardware
identity storage. **Everything stored in `/root` is reset**, including software
credentials and network configuration. Identity that must survive cannot live
only there. Keep a local serial/recovery path; network access may disappear.

Hardware qualification is still pending: test reset on expanded p3, busy-unmount
and I/O failures, and power cuts during invalidation and reformatting. Verify
empty usable storage and unchanged firmware/identity after recovery. The standard
reset is not an atomic transaction: interruption may leave old data or an invalid
filesystem, so do not claim completion until the post-boot checks pass.

## SD, CAN, and serial ports

| Interface | Linux device | Board pins |
| --- | --- | --- |
| SPI SD slot | `mmcblk1` when a card is present | SPI1: GPIO1_B3 CS, B2 MOSI, C2 clock, C3 MISO |
| UART3 | `/dev/ttyS3` | GPIO0_A2 TX, A3 RX |
| UART4 | `/dev/ttyS4` | GPIO0_B0 TX, A0 RX |
| CAN0 | `can0` (verify controller mapping) | GPIO0_C3 TX, C4 RX |
| CAN1 | `can1` (verify controller mapping) | GPIO0_C1 TX, C2 RX |

The SD slot uses 3.3 V, a maximum 20 MHz SPI clock, and card-detect polling.
Explicit MMC aliases keep eMMC at `mmcblk0` and the SPI slot at `mmcblk1`.
Verify `/proc/partitions` and `/sys/class/block/mmcblk1/device/type` before mounting
an SD partition read-only. Never format a guessed device. Test booting both with
and without an inserted card before relying on this setup.

CAN controllers are enabled but not automatically brought up. Set the bitrate to
match the peer, verify connector mapping, and use correct bus termination. An
internal loopback test does not verify the transceivers or connector wiring.

UART3/4 use TX/RX without DE GPIO, RTS polarity, or boot-time RS485 mode settings.
A two-port Modbus RTU write/read test passed with both client/server orientations
at 9600 baud, 8N1, without software direction control. This supports using the
hardware's automatic direction handling at these settings; other speeds and bus
loads remain unqualified. Do not connect a TTL UART adapter directly to RS485 A/B
terminals. UART0 remains the boot console.

The SPI SD slot has passed card detection, read-only FAT mounting, directory
listing, and unmounting, with eMMC numbering preserved. SD file contents and
writes remain untested. Reboot with an inserted SD card works with the included
[MMC regulator fix](https://github.com/armbian/linux-rockchip/issues/563).
Both CAN interfaces register, but physical CAN traffic has not been tested.

## User controls

| LED | GPIO | Linux LED name |
| --- | --- | --- |
| RUN | GPIO1_A7 | `ec100:run` |
| USER1 | GPIO1_A6 | `ec100:user1` |
| USER2 | GPIO1_A4 | `ec100:user2` |

These GPIO mappings come from the [IOTRouter EC100 guide](https://en.iotrouter.com/ec100-arm-industrial-computer-development-guide/)
(RUN/LED1/LED2) and match the captured stock device tree. All three have pinctrl
and `gpio-leds` definitions. **Physical polarity is still unverified**:
`GPIO_ACTIVE_HIGH` currently makes brightness `0` raw low and `1` raw high.
Observe each LED at both values before treating them as physical off/on.

All three use `default-state = "off"` (raw low) when the Linux driver probes,
rather than inheriting the bootloader output. Earlier boot stages are unchanged;
no early-boot blink is promised. Control them through `/sys/class/leds/<name>/`
or application-level [Delux](https://github.com/elixir-circuits/delux). The kernel
includes the timer, transient, and pattern triggers; pattern supports Delux.

RUN is **not a VM-health guarantee**. A latched brightness or repeating kernel
pattern can survive an abrupt VM failure. Applications needing a timeout can use
the standard transient trigger, but physical off-on-crash behavior still needs
polarity and failure testing. Heart/watchdog recovery remains separate; no LED
supervisor is added by this system.

The user button is GPIO1_A5, active-low, exposed by `gpio-keys` as `KEY_PROG1`
(code 148). Press/release events have been verified. No reset action is bound.

## USB

USB0 (`ff740000.usb`) uses the Type-C connector as a fixed CDC ECM Ethernet
peripheral for laptop setup. It is not an OTG host port. Power the EC100 separately;
the Type-C host VBUS switch (GPIO1_D0) remains claimed and off. MASKROM flashing
and recovery remain independent of Linux USB support.

For an application using `vintage_net_direct`, include this entry in its
`:vintage_net` configuration:

```elixir
{"usb0", %{type: VintageNetDirect}}
```

VintageNetDirect derives a /30 subnet from the hostname and interface, and serves
DHCP to the laptop. On the test board, the addresses are `172.31.92.201` (EC100)
and `172.31.92.202` (laptop). The application must provide SSH and an authorized key.

Current status (Linux laptop, system `0.1.28-dev`):
- Booting unplugged, then connecting passed USB SSH/ping and three reconnect cycles.
- Booting with Type-C connected stalled USB traffic; unplug/replug did not recover
  it. One USB0 software disconnect/connect restored operation without a reboot.
- Usable for development with Ethernet as a fallback; boot-connected reliability
  remains unresolved. macOS and Windows are untested.

The tested `0.1.28-dev` build uses local PHY/DWC2 patches to keep USB0 in device
mode and allow reconnect resets despite missing session-valid sensing. The PHY
stays awake; gadget state/carrier may remain stale while unplugged.

`0.1.30-dev` is an **unqualified bulk-OUT guard candidate**. It retains the PHY
and DWC2 reconnect patches and explicitly sets NAK on bulk OUT endpoint setup;
the existing request-start path clears NAK after programming a receive buffer.
This targets the observed early-traffic startup failure without a startup delay,
tracing, or automatic reset. One temporary boot passed USB SSH/ping, but host
traffic arrived late; the failing early-traffic sequence and reconnect behavior
remain unvalidated for this candidate. Do not replace a known-good slot with it.

USB1 (`ff780000.usb`) is enabled as an internal host with USB serial (`option`),
CDC ACM, and CDC ECM drivers. No modem is fitted, so device operation is untested;
modem power/reset and networking are not configured. Before adding a USB-network
modem, verify interface identity so it cannot inherit the setup port's
`VintageNetDirect`/DHCP-server configuration.

## Kernel profile

This wired, headless profile enables strict kernel memory permissions: kernel
code and read-only data are protected against writes, and writable kernel data
is non-executable. Unused Rockchip RGA graphics, audio, Bluetooth, and Wi-Fi stacks
are disabled. Wi-Fi, Bluetooth, and audio peripherals require a different kernel
configuration; USB Ethernet and the other documented interfaces remain enabled.

## Tailscale gateways

`0.1.31-dev` adds built-in TUN, IPv6 and dual-stack policy routing, plus netfilter
support for Tailscale's default **iptables** backend. The image includes
`iptables` and `ip6tables`, with kernel support for filtering, connection tracking,
NAT/masquerading, packet/connection marks and TCP MSS clamping. The nftables
backend is not enabled.

`0.1.32-dev` adds built-in LAN bridging, `bridge-utils`, and firewall comment
matching and IPv4/IPv6 REJECT targets in `linux/ec100.fragment`. Bridge
netfilter is disabled so ordinary Layer-2 bridge traffic does not pass through
the IP firewall; routed traffic can still be filtered. The application owns
bridge configuration and supplies `tailscaled` during firmware assembly.

The application still needs to start Tailscale in kernel-TUN mode, enable the
required IP forwarding sysctls on each boot, and advertise only the intended
routes. Route approval and access rules belong to the tailnet configuration.
This system does not automatically enable forwarding or advertise routes.
Gateway operation still needs hardware validation; `/dev/net/tun` existing alone
is not proof that routing and NAT work.

## Watchdog

The GPIO watchdog is configured on GPIO0_B1 with toggle feeding, `always-running`,
and `nowayout`. Heart opens `/dev/watchdog0` (expected identity: `GPIO Watchdog`)
with a 60-second timeout. The 10-second hardware feeding margin is provisional,
not a measured circuit timeout.

Hardware watchdog recovery is verified on the EC100. **Remove the watchdog-disable
jumper for normal operation**; leaving it fitted disables hardware watchdog resets.
With `nowayout`, closing the watchdog device does not disarm it.

### Application setup

The hardware driver is configured by this system. In the application, enable the
standard startup guard in `config/target.exs`:

```elixir
config :nerves_runtime, startup_guard_enabled: true
```

Enable Heart and its initialization handshake in `rel/vm.args.eex`:

```text
-heart -env HEART_BEAT_TIMEOUT 30
-env HEART_INIT_TIMEOUT 600
```

StartupGuard sends the required Heart initialization handshake, waits for the
expected OTP applications to start, then validates the firmware. Internet
connectivity is not required.

**Keeping `HEART_INIT_TIMEOUT` without a handshake can trigger recovery even when
the VM is healthy.** If replacing StartupGuard with custom startup logic, that
logic must arrange the handshake and firmware validation instead. These VM and
initialization timeouts are separate from the hardware watchdog timing.

Nerves Heart handles watchdog feeding; do not add a separate GPIO-feeding process.

## Remaining qualification

Automatic A/B rollback, power-loss recovery, LED polarity/VM-failure behavior,
factory reset, CAN traffic, and long-term stability still require hardware
qualification.

## Configuration

- `dts/rk3506-ec100.dts` — board hardware
- `linux/ec100.fragment` — board kernel features, bridging, routing and firewall support
- `bootstrap/uboot.env` — boot selection and rollback
- `fwup.conf` — storage layout and firmware updates
- `fwup-ops.conf` — validation, revert, and factory reset

## Tests

Run the factory-flashing tests without building the system:

```sh
elixir -r lib/mix/tasks/ec100.flash.ex -r test/test_helper.exs -r test/ec100_flash_test.exs -e 'Mix.start()'
```
