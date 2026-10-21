# Changelog

## Unreleased

### Fixed

- Reject developer-platform applications from device archives, alongside firmware and simulator applications.

### Fixed

- Packaging rejects disagreement between the SDK dependency range and the application's declared SDK compatibility range.

## 0.1.0 - 2026-10-21

### Added

- Portable system, network, event, storage, CAN, RS485 and equipment APIs through one backend behaviour.
- Build standard production OTP `.ez` application archives with SDK and platform compatibility checks (`mix nerves_gate.package [--output path]`).
