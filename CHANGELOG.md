# Changelog

## Unreleased

### Breaking changes

- Use the platform checkout as the developer environment. Create/open ordinary SDK applications directly in the workbench, or use `mix app.new PATH`; no generator archive or solution manifest is needed.
- App test, package and install commands take an application directory. The optional `mix dev PATH` opens that application; plain `mix dev` starts the workbench. QEMU scenarios use `mix test.qemu`.
- Firmware and simulator versions follow the platform version. The SDK retains its independent version and Hex package; firmware, simulator and generator are no longer published on Hex. Existing 0.1.x packages remain available.
- Solution firmware defaults to a local build from the checkout. Supply a compatible `.fw` path in `nerves_gate.exs` for cross-version work.

### Added

- The developer workbench creates/opens applications and offers explicit test, package, simulator install and EC100/QEMU firmware-build actions.
- Physical firmware updates use verified-host SSH public-key authentication, image/device compatibility review, SHA-256 and a single-use typed confirmation before upload and reboot. No initial provisioning or disk formatting is performed.
- Local mDNS discovery lists advertised Nerves Gate gateways without subnet scans or VPN changes. Known IPv4 addresses can be added manually. New firmware advertises public device metadata; discovery is not authentication.
- `mix app.console` prints the SSH command only while an owned simulated device has idle Manual control.
- Generated apps demonstrate pure decisions over SDK observations and ordinary host unit tests. Generated Elixir files are formatted.
- Prerequisite errors include Linux installation guidance and the macOS Linux-VM route.

### Fixed

- Manual device entries accept DNS names, including Tailscale names, as well as IPv4 addresses.
- Workstation commands select the host even when the shell carries a device Mix target; firmware commands retain their selected target.
- Clean device builds initialize the Nerves toolchain before compiling native dependencies; workstation binaries are not shipped to musl guests.
- Boot failures retain bounded, secret-free domain liveness diagnostics separately from the gateway status query.
- Invalid RTC time handling uses the `nerves_time` 0.4.14 fix.

Earlier component history is preserved in the immutable [firmware/v0.1.0](https://github.com/sid2baker/nerves_gate/tree/firmware/v0.1.0), [sim/v0.1.0](https://github.com/sid2baker/nerves_gate/tree/sim/v0.1.0) and [new/v0.1.1](https://github.com/sid2baker/nerves_gate/tree/new/v0.1.1) tags.
