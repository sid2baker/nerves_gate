# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- AIC8800D80 USB Wi-Fi and Bluetooth driver/firmware package, with
  wpa_supplicant and BlueZ tools. Radios remain hardware-unqualified and no
  network, access point or Bluetooth pairing service starts by default.

- Initial Nerves system for the IOTRouter EM300 (RK3506, 512 MiB SPI NAND),
  derived from `nerves_system_ec100`.
- SPI NAND layout with raw A/B kernel FIT slots, a redundant U-Boot environment
  partition and UBI volumes for A/B SquashFS root filesystems and UBIFS data.
- fwup A/B upgrades using `ubi_volume_write` and a verified raw kernel-slot
  writer; runtime validate, revert, status and factory-reset operations.
- `mix em300.flash` MaskROM factory installation with full NAND backup and
  readback verification.
- EM300 device tree: Ethernet, CAN, four field UARTs, the extension-module
  UART, SD card, DS1307 RTC, LEDs, keys and named GPIO lines. The stock
  PCA9555 node is omitted because the chip does not respond on this board.
- External GPIO watchdog for Heart, matching stock: `WATCHDOG_ENABLE` hogged
  high and `WATCHDOG_KICK` toggled about every 5 s. The hardware timeout is
  unqualified.
