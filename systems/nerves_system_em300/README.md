# nerves_system_em300

[Nerves](https://nerves-project.org/) system for the **IOTRouter EM300**, based on
the Rockchip RK3506B (3× Cortex-A7, 512 MiB RAM) with **512 MiB SPI NAND**.

- Source-built U-Boot and Linux with pinned Rockchip DDR, SPL, and secure firmware
- A/B firmware updates on SPI NAND (raw kernel FIT slots + UBI root filesystems)
  with application validation and boot-count rollback
- Persistent UBIFS application storage at `/data` (`/root`)
- Ethernet, CAN, four field UARTs, the extension-module UART, microSD,
  DS1307 RTC, the external watchdog and a **115200 8N1** serial console

**Status: bring-up.** Derived from the stock EM300 device tree and the
`nerves_system_ec100` boot chain. Nothing has been booted on hardware yet.

## Build

Requires Nerves 2 (currently `2.0.0-pre.4`), like `nerves_system_ec100`. In this
monorepo firmware selects the local path with `NERVES_GATE_LOCAL_DEPS=1`. There is
no published artifact yet; build it explicitly (Docker or Podman required):

```sh
MIX_TARGET=em300 mix nerves.artifact.build nerves_system_em300
MIX_TARGET=em300 mix firmware
```

The build produces application firmware (`.fw`) and separate factory boot images.
It does not flash the board. Source pins are listed in [SOURCES.md](SOURCES.md);
boot-image details are in [bootstrap/README.md](bootstrap/README.md).

## Storage

| NAND region | Offset | Size | Linux |
| --- | ---: | ---: | --- |
| `idblock` (DDR init + SPL copies) | 0 | 4 MiB | `mtd0`, read-only |
| `uboot` (U-Boot/TEE FIT) | 4 MiB | 4 MiB | `mtd1`, read-only |
| `env` (redundant U-Boot env at +0, +128 KiB) | 8 MiB | 1 MiB | `mtd2` / `mtdblock2` |
| `kernel_a` (raw kernel FIT) | 9 MiB | 16 MiB | `mtd3` |
| `kernel_b` (raw kernel FIT) | 25 MiB | 16 MiB | `mtd4` |
| `ubi` | 41 MiB | 470 MiB | `mtd5` → `ubi0` |
| Reserved for Rockchip bad-block/GPT data | 511 MiB | 1 MiB | — |

UBI volumes on `ubi0`:

| ID | Name | Size | Use |
| ---: | --- | ---: | --- |
| 0 | `rootfs_a` | 128 MiB | SquashFS, `/dev/ubiblock0_0` when slot A boots |
| 1 | `rootfs_b` | 128 MiB | SquashFS, `/dev/ubiblock0_1` when slot B boots |
| 2 | `data` | rest (~190 MiB) | UBIFS at `/root`, formatted by UBIFS on first mount |

The layout is defined once per consumer: `bootstrap/parameter.txt` (Rockchip
GPT used by SPL/U-Boot and `rkdeveloptool`), the device tree's fixed partitions
(Linux), `fwup.conf` and `rootfs_overlay/etc/fw_env.config`. The system tests
check that they agree.

## Factory installation

**Factory flashing erases the entire SPI NAND**, including the vendor firmware,
its recovery system and its vendor-storage area. Keep the vendor image and its
reflash procedure, plus the backup this task creates.

Requirements: `rkdeveloptool`, `fwup`, `ubinize` (mtd-utils) and Elixir/OTP.
Put the EM300 into MaskROM (hold the LOADER key — SARADC channel 0 — while
powering on) and connect its USB-C download port. From the application:

```sh
MIX_TARGET=em300 mix em300.flash
```

The task builds firmware, stages the factory images offline (environment from
the archive's `factory-env` task, UBI image with `rootfs_a` from the archive),
asks for confirmation, reads a full NAND backup to `em300-backups/`, erases the
NAND, writes GPT, two IDB copies outside GPT's erase block, U-Boot, kernel slot A, the UBI image and the
environment, reads back every region and resets the board.

USB commands use `sudo -n` by default; authenticate beforehand or use `--no-sudo`
with suitable USB permissions. Other options are `--no-reset`, `--yes` and
`--no-backup`.

## OTA updates

The `.fw` upgrade tasks write the inactive slot outside fwup's destination:

- the root filesystem with `ubi_volume_write("/dev/ubi0_N")` (atomic UBI update);
- the kernel FIT with `/usr/sbin/em300-write-kernel`, which erases the raw slot,
  writes it with `nandwrite -p` and verifies a `nanddump` readback.

Both require `fwup --unsafe`. The destination (`nerves_fw_devpath`) is the env
partition `/dev/mtdblock2`, where fwup updates the redundant environment as on
block-device systems. Applications must pass `--unsafe` to `ssh_subsystem_fwup`
and `Nerves.Runtime.FwupOps` (`fwup_extra_options: ["--unsafe"]`), and set the
FwupOps `devpath` to `/dev/mtdblock2`.

Rollback follows `nerves_system_ec100`: with `bootlimit=3`, an unvalidated trial
gets three boot attempts; the fourth rolls back. Validation clears the trial.

## Factory reset (application data only)

`Nerves.Runtime.FwupOps.factory_reset()` truncates the `data` UBI volume
(`ubiupdatevol -t /dev/ubi0_2`, requires `--unsafe`). UBIFS formats the empty
volume on the next mount. The application must stop data writers and unmount
`/root` first; a mounted volume is busy and the reset fails. This is not secure
erasure.

## Hardware

| Function | Linux | Notes |
| --- | --- | --- |
| Console | `ttyS0` (UART0) | 115200 8N1 |
| Field serial | `ttyS1`–`ttyS4` | UART1–4; transceiver types unqualified |
| Extension modules | `ttyS5` (UART5 M1) | 921600 8N1 daisy-chain bus |
| CAN | `can0`, `can1` | RK3506 CAN-FD controllers |
| Ethernet | `eth0`, `eth1` | RMII PHYs |
| microSD | `mmcblk0` | card detect on GPIO0_B0 |
| RTC | DS1307 @ I2C0 0x68 | `rtc0` |
| LEDs | `em300:led0..2`, `em300:som`, `em300:user` | polarity unqualified |
| Keys | `KEY_PROG1` (front), `KEY_PROG2` (user2) | active-low |
| 4G modem | Quectel `2c7c:6002` | powered at boot; reset line unclaimed |

Named GPIO lines on `gpiochip1` (use them by name from Circuits.GPIO):
`DI0`, `DI1`, `DO0`, `DO1` (main-board I/O), `EXT_LINK`, `EXT_RESET`,
`EXT_ERROR_LED` (extension bus), `UPS_DETECT`, `UPS_POWER_CTRL`, `WWAN_RESET`,
`WATCHDOG_ENABLE`. The HDMI bridge is not supported.

## Wi-Fi and Bluetooth (unqualified)

The internal USB AIC8800D80 uses one source-built package containing
`aic_load_fw`, `aic8800_fdrv`, `aic_btusb` and the D80 firmware. NervesUEvent
loads the modules through their USB aliases; no custom loader service is needed.
The firmware loader handles the transition from USB `a69c:8d80` to `a69c:8d81`.

Wi-Fi uses cfg80211/nl80211, wpa_supplicant and VintageNetWiFi. No network or
access point is configured by default. Bluetooth uses the Linux HCI interface
and includes BlueZ tools; pairing, discoverability and a Bluetooth application
service are not enabled automatically. Driver inclusion is not hardware
qualification: verify firmware loading, Wi-Fi client/AP operation and Bluetooth
controller discovery/pairing after first boot. Concurrent Wi-Fi/AP/Bluetooth
operation also remains untested.

## Watchdog (unqualified)

The EM300 carries an external toggle-fed supervisor like the EC100's. Stock
firmware leaves `WATCHDOG_ENABLE` (GPIO1_D0) at its pull-down level during
boot; its application then drives it high and toggles `WATCHDOG_KICK`
(GPIO1_D1) about every 10 s. This system hogs enable high in the kernel and
feeds with gpio-wdt (`always-running`, `nowayout`, `hw_margin_ms` 10000, so
about every 5 s). Heart opens `/dev/watchdog0` (`GPIO Watchdog`). The SoC
watchdogs are disabled.

Observed: stock firmware stays up with enable high and ~10 s feed intervals.
Low-at-boot safety is inferred from boot behavior and pin pulls, not measured
electrically. Enable polarity and the actual hardware timeout remain unqualified.
Qualify with UART0 capture and a recovery path available:

1. Confirm `/dev/watchdog0` exists and the board stays up.
2. Stop the VM (`:init.stop()`); with `nowayout` feeding stops. The time from
   the last feed to reset is the hardware timeout. Set the margin from it.
3. If no reset occurs, investigate enable polarity and whether feeding really
   stopped; lack of reset alone does not establish polarity. Testing enable-low
   requires changing/releasing the kernel GPIO hog first, not overriding it with
   Circuits.GPIO. If the external circuit is unusable, qualify `wdt0` instead.
4. Repeat the EC100's A/B rollback test.

## Remaining qualification

Everything: first boot from NAND, U-Boot environment and bad-block handling,
A/B update and rollback, data volume, peripherals and LED/key polarity.
