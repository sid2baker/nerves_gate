# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

## 0.3.0 - 2026-10-22

### Added

- Enable power to the Quectel EG800AK 4G module using the factory GPIO1_C0
  power-enable line.
- Name the EG800AK's CDC-ECM data interface `wwan0`, keeping `usb0` reserved for
  the Type-C recovery link.
- Document the active-high modem reset on GPIO1_D1; the system leaves it
  unclaimed and does not automatically reset the modem.

## 0.2.2 - 2026-10-22

### Changed

- System builds use Nerves 2 artifact tooling and Buildroot's source fetching and
  license collection instead of a separate toolchain-source downloader.

## 0.2.1 - 2026-10-20

### Changed

- System sources and prebuilt artifacts are now available from `sid2baker/nerves_gate`,
  using `system-ec100/v0.2.1` instead of releases in the standalone system repository.

### Compatibility

- Uses Nerves `2.0.0-pre.4`, matching the gateway firmware build tools.

## 0.2.0 - 2026-10-15

### Added

- Nerves 2 system for the IOTRouter EC100, with source-built Linux and U-Boot,
  Ethernet, eMMC storage, and A/B firmware updates.
- Factory installation with eMMC backup and write verification.

### Compatibility

- Requires Nerves 2 (currently `2.0.0-pre.3`); Nerves 1 applications must migrate
  before using this system.
