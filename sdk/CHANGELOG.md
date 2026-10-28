# Changelog

## Unreleased

### Breaking changes

- Plugin terminology replaces application terminology: `Network.Interface.plugin_enabled?` replaces `application_enabled?`, and errors such as `application_not_running`/`applications_blocked` are now `plugin_not_running`/`plugins_blocked`. No aliases.
- Local Ethernet claims require an enabled exclusive assignment to the actual managed plugin. Declare `:ethernet` in `nerves_gate_hardware`; a network plugin-role flag alone grants no access. Hardware resources include Ethernet interfaces and network observations expose the assigned plugin.
- Removed CAN/RS485 claim, subscription and byte-I/O APIs. Plugins query their caller-derived exclusive assignments through `Hardware.resources/0` and supervise ordinary transport libraries directly. Reassignment requires checked whole-plugin stop; Internet/local-network leases retain their separate platform contract.
- `circuits_uart` is a shared firmware library, never a private plugin native payload; packaging records its exact compatible platform version.

- Phoenix/LiveView and Req HTTP libraries are shared with firmware, not bundled as private copies. Packaging records exact shared platform versions, including transitive dependencies; align application lockfiles with the target firmware before rebuilding.

- Stateful subscriptions, hardware assignment queries and network leases require a managed activation. The firmware derives generation scope from the actual caller, rejects stale scope, and drains resources before reactivation. Read-only SDK queries remain available outside apps. Resource calls are not maintenance RPCs; no proxy Task becomes owner.

- Removed `Equipment.list/0`, its device struct and the `:equipment` event topic. Applications own equipment identities, discovery and protocols; use `Network.interfaces/0` for platform link observations.

### Added

- Optional `:nerves_gate_ui` declaration for a verified app-owned LiveComponent hosted by the gateway. Its callbacks call the app's supervised commands rather than borrowing SDK resource ownership from the gateway LiveView.
- Process-owned isolated Ethernet leases through `Network.claim_local/3`, `local_status/0`, `advertise_local/1` and `release_local/1`. Claiming never changes Internet/USB, creates DNS/default routes or advertises automatically. Unknown cleanup blocks reuse.
- Typed local lease observations and `Network.Interface.plugin_enabled?`/`claimed?` flags, without private process or claim handles in public observations.

### Fixed

- Reject developer-platform applications from device archives, alongside firmware and simulator applications.
- Packaging rejects disagreement between the SDK dependency range and the application's declared SDK compatibility range.

## 0.1.0 - 2026-10-21

### Added

- Portable system, network, event, storage, CAN, RS485 and equipment APIs through one backend behaviour.
- Build standard production OTP `.ez` application archives with SDK and platform compatibility checks (`mix nerves_gate.package [--output path]`).
