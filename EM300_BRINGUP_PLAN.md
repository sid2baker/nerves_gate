# IOTRouter EM300: Nerves bring-up

## Scope and authorization

The EM300 is a dedicated development unit. The operator grants SSH access and
accepts that the stock system may be broken: the vendor image and reflash
procedure are the recovery path. Authorized on this unit: inspection, copying
files to the host, experiments on the stock system and, once MaskROM access is
confirmed, flashing EM300 Nerves images. Still requires a separate request:
workstation networking changes, other devices, publishing/tags/commits/pushes,
and anything touching connected field equipment.

Goal: an independent `systems/nerves_system_em300`, an `em300` firmware target,
and the connected extension modules exposed as hardware. Plugins keep owning
equipment protocols and use cases.

Private evidence (git-ignored): `_build/em300-evidence/` — `FINDINGS.md`, stock
device tree, `dmesg`, MTD partition dumps, root filesystem archive, UART captures.

## 1. Stock inventory — done

- RK3506B, 512 MiB RAM, GigaDevice 512 MiB SPI NAND (no eMMC), microSD slot.
- Stock: Buildroot 2024.02, Rockchip 6.1.99-rt, vendor U-Boot (unsigned FITs),
  SPI NAND mtdparts + UBI root. `reboot loader` and an unpopulated LOADER
  (SARADC ch0 MaskROM) key are available.
- Peripherals: 2× RMII Ethernet, 2× CAN-FD, UART1–4 field ports, UART5
  extension bus, PCA9555, DS1307, Quectel `2c7c:6002`, AIC8800 Wi-Fi.
- GPIO consumers named: main-board DI0/1, DO0/1, LEDs, key, UPS, modem,
  external watchdog, extension link/reset/error LED.

Open: first 4 MiB (IDB) only readable over MaskROM; field-port transceiver
types; LED polarity; external watchdog timeout; PCA9555 consumers.

## 2. Extension modules — protocol decoded

Stock `slave-agent` drives a daisy chain on `/dev/ttyS5` (921600 8N1) with
`EXT_RESET`/`EXT_LINK` GPIOs. Frames `AA func len payload crc16 55`
(CRC-16/MODBUS, little-endian); search → config → start, then cyclic `N×32`-byte
input frames every ~11 ms; DO writes `AA 31 21 addr <32 bytes>` without ack,
confirmed by the cyclic echo. Connected: D1600 (16 DI) at 1, D0016N (16 DO) at 2.

Open: DI byte encoding (needs a stimulus), AI/AO formats, config bytes.

Firmware design: one supervised I/O-domain process owns `ttyS5` and the
extension GPIOs, runs discovery and the cycle, and exposes module channels as
stable I/O identities. Writes are confirmed by echo and never blindly replayed.

## 3. Nerves system — implemented, not yet booted

`systems/nerves_system_em300`, derived from `nerves_system_ec100`:

- NAND layout (GPT `bootstrap/parameter.txt` = DT fixed partitions):
  `idblock` 4 MiB, `uboot` 4 MiB, `env` 1 MiB (redundant env), `kernel_a`/`kernel_b`
  16 MiB raw FIT slots, `ubi` 470 MiB with `rootfs_a`/`rootfs_b` (SquashFS via
  ubiblock) and `data` (UBIFS at `/root`); 1 MiB tail reserved.
- U-Boot: BSP `rk3506_defconfig` with SPI NAND, env in the block device through
  Rockchip's bad-block-mapping MTD block layer, A/B + bootcount env from fwup.
- fwup 1.17 `ubi_volume_write` for root filesystems, `em300-write-kernel`
  (erase, `nandwrite -p`, readback) for kernel slots; destination `/dev/mtdblock2`.
  Requires `--unsafe`. Standard Nerves validate/revert/status via `ops.fw`.
- `mix em300.flash`: MaskROM install (backup, `ef`, `ul`, `gpt`, `wlx`,
  readback, reset). Requires host `ubinize` (mtd-utils).
- System tests check GPT/DT/fwup/fw_env agreement and run real fwup tasks.

Reference: `nerves_system_openwrt_one` (UBI A/B on SPI NAND); EM300 differs by
keeping fwup upgrades and a SquashFS root instead of an initramfs.

## 4. Firmware and Workbench — integrated

- Firmware `em300` target (`config/em300.exs`): UBIFS data check, board-declared
  CAN/serial ports (`Hardware.Ports`), `--unsafe` and `/dev/mtdblock2` for
  `ssh_subsystem_fwup` and FwupOps; modem, LEDs and recovery key disabled until
  qualified. Builds need `NERVES_GATE_LOCAL_DEPS=1` and the local system artifact.
- Workbench: `mix firmware em300`, Build page, image lists per board, gateway
  directory and plugin install accept `em300`, firmware update rejects EC100 ↔
  EM300 images both ways, `/provision` selects the board from the image and runs
  `em300.flash`'s engine (SPI NAND capacity, `ERASE EM300 <location>`).

## 5. Next steps

1. MaskROM: solder LOADER key; install host `mtd-utils`; first `/provision` run
   with console capture.
2. Qualify boot, NAND env, A/B update/rollback, data volume, peripherals.
3. Extension-module I/O domain on `ttyS5`; modem, LEDs and recovery key.
4. Publish `nerves_system_em300` and add CI firmware/system jobs when requested.
