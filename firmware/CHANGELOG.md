# Changelog

## Unreleased

### Added

- Hardware-free unit tests for input validation, LED policy, equipment labels and Modbus RTU framing run in host CI.

### Changed

- Align firmware and simulator locks on `nerves_time` 0.4.14, including its invalid-RTC-time fix, so clean locked dependency fetches remain reproducible.

### Fixed

- Limit the Phoenix code-reload listener to host development. On clean device builds it could compile native dependencies before Nerves selected the cross-compiler, shipping workstation binaries and preventing guest networking from initializing.

## 0.1.0 - 2026-10-21

### Added

- Device SDK backend: typed system, network, storage and equipment observations, process-owned subscriptions, exclusive RS485 claims and CAN frames.
- Trusted OTP application runtime on SD storage with install, cold upgrade, health-checked rollback and uninstall.
- Application-storage commissioning supports prepared cards, explicit erase confirmation, skipping storage, and card removal/restoration.
- Shared gateway UI and host tools are available as a Hex package; device builds select their system sources and artifacts separately.
- CAN interfaces can be explicitly configured in normal mode for application transmission; listen-only remains the default.
