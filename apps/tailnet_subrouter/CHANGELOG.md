# Changelog

## Unreleased

## 1.1.0 - 2026-10-26

### Added

- Gateway application page for configuring a local address, inspecting link and sharing state, and explicitly enabling or disabling subnet sharing.

### Compatibility

- Requires managed-activation and app-page support in Nerves Gate firmware, SDK `~> 0.2.0-dev`, and the exact Phoenix/LiveView platform versions recorded in the release manifest. Opening the page never configures or advertises a network; sharing is not replayed after restart.
