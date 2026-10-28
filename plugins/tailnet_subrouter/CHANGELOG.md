# Changelog

## Unreleased

### Breaking changes

- Version 0.1.4 requires exclusive Ethernet assignment under Hardware. The interface picker rejects unassigned and other-plugin LANs; claiming still uses the supervised plugin owner and checked platform cleanup.

### Compatibility

- Version 0.1.3 gives the current bundled artifact a new immutable identity. Saved 0.1.2 remains unchanged; selection and activation are explicit.

## 0.1.2 - 2026-10-27

### Compatibility

- Rebuilt for the renamed Hardware inventory domain and administrative schema 11.

## 0.1.1 - 2026-10-27

### Compatibility

- Packages the subnet router against the firmware's current hardware-assignment SDK. Select this version explicitly when upgrading from 0.1.0; firmware never substitutes changed code under an existing plugin version.

## 0.1.0 - 2026-10-26

### Added

- Opt-in subnet routing over the gateway's existing Tailscale connection, with explicit local address configuration, advertisement and checked cleanup.
- Gateway application page for configuring a local address, inspecting link and sharing state, and explicitly enabling or disabling subnet sharing.

### Compatibility

- Requires managed-activation and app-page support in Nerves Gate firmware, SDK `~> 0.2.0-dev`, and the exact Phoenix/LiveView platform versions recorded in the release manifest. Opening the page never configures or advertises a network; sharing is not replayed after restart.
