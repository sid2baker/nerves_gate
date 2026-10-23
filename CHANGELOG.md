# Changelog

## Unreleased

### Breaking changes

- Use the platform checkout as the developer environment. Create/open ordinary SDK applications directly in the workbench, or use `mix app.new PATH`; no generator archive or solution manifest is needed.
- App test, package and install commands take an application directory. The optional `mix dev PATH` opens that application; plain `mix dev` starts the workbench. QEMU scenarios use `mix test.qemu`.
- Firmware and simulator versions follow the platform version. The SDK retains its independent version and Hex package; firmware, simulator and generator are no longer published on Hex. Existing 0.1.x packages remain available.
- Simulated devices use firmware built locally from the platform checkout by default.
- The simulator is part of the root project: `NervesGateSim` modules are now `Simulator` in `lib/simulator/`, and bench configurations moved from `sim/priv/qemu/` to `priv/simulator/`. Tailnet gateway discovery for `mix dev.ui` is `Dev.TailnetDiscovery`.

### Added

- Developer workbench factory provisioning for EC100 over USB MASKROM, with a
  reviewed image, a full eMMC backup by default (skipping it needs a stronger
  confirmation), explicit physical-board/erase confirmation, verified readbacks
  before reset and a read-only USB reconnection check afterwards.
- EC100 4G support for the Quectel EG800AK-GL using CDC-ECM, an operator APN and
  the existing Internet-source and Ethernet-backup settings, the network's default
  APN unless overridden, and SIM PIN commissioning with an optional SIM-bound saved
  PIN for automatic unlock. The USB recovery link stays separate.
- Cellular inbound protection is installed before saved network connections are
  restored, keeping unsolicited mobile traffic away from the unauthenticated UI
  and SSH. Firmware refuses startup if this protection cannot be installed.
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
- Firmware and app builds no longer occasionally crash with `:epipe` and lose
  their exit status when a command finishes.

Earlier component history is preserved in the [firmware](https://github.com/sid2baker/nerves_gate/tree/b7f474dd5639e55ef31fbd3e7dc35de786ade27a), [simulator](https://github.com/sid2baker/nerves_gate/tree/7fe074e82db853fd344fb12f75730ad91016b963) and [generator](https://github.com/sid2baker/nerves_gate/tree/9d1b3d9854c3e05fdbcc0e65b12db5cda37b7eb4) source commits.
