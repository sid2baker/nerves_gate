# Changelog

## Unreleased

### Changed

- Simulator modules use `NervesGateSim` and `NervesGateSimWeb`; product scenarios live under `sim/scenarios` and are not shipped in the Hex package.
- Boot failures record bounded, secret-free domain liveness diagnostics independently of the gateway status query.
- Align the shared `nerves_time` lock with firmware at 0.4.14 for clean dependency fetches.

### Added

- `mix nerves_gate.sim.console` prints a guest SSH command only while that device has idle Manual ownership.
- Prerequisite failures include Linux installation guidance and the macOS Linux-VM route.

## 0.1.0 - 2026-10-21

### Added

- Disposable QEMU gateways running real Nerves Gate firmware on private socket networks, with a virtual SD card.
- `mix nerves_gate.sim` starts the simulator site; `mix nerves_gate.sim.install` packages the current application and runs it on a device.
- Manual cable, uplink and VM controls, and the shared admission runner for firmware integration scenarios.
