# Changelog

## Unreleased

### Breaking changes

- Removed `Equipment.list/0`, its device struct and the `:equipment` event topic. Applications own equipment identities, discovery and protocols; use `Network.interfaces/0` for platform link observations.

### Added

- Process-owned isolated Ethernet leases through `Network.claim_local/3`, `local_status/0`, `advertise_local/1` and `release_local/1`. Claiming never changes Internet/USB, creates DNS/default routes or advertises automatically. Unknown cleanup blocks reuse.
- Typed local lease observations and `Network.Interface.application_enabled?`/`claimed?` flags, without private process or claim handles in public observations.

### Fixed

- Reject developer-platform applications from device archives, alongside firmware and simulator applications.
- Packaging rejects disagreement between the SDK dependency range and the application's declared SDK compatibility range.

## 0.1.0 - 2026-10-21

### Added

- Portable system, network, event, storage, CAN, RS485 and equipment APIs through one backend behaviour.
- Build standard production OTP `.ez` application archives with SDK and platform compatibility checks (`mix nerves_gate.package [--output path]`).
