# Changelog

## Unreleased

### Breaking changes

- Use the platform checkout as the developer environment. Create separate solution repositories with `mix solution.new PATH` and open them with `mix dev PATH`; the standalone generator and package-based workspaces are no longer the recommended workflow.
- Workstation commands run from the platform checkout. Use `mix app.new`, `app.test`, `app.package`, `app.install` and `app.console` with `--solution PATH`, or the solution opened by the running workbench. QEMU scenarios use `mix test.qemu`.
- Firmware and simulator versions follow the platform version. The SDK retains its independent version and Hex package; firmware, simulator and generator are no longer published on Hex. Existing 0.1.x packages remain available.
- Solution firmware defaults to a local build from the checkout. Supply a compatible `.fw` path in `nerves_gate.exs` for cross-version work.

### Added

- The developer workbench shows the open solution, its platform compatibility and applications, with explicit test, package, install and QEMU firmware-build actions.
- `mix app.console` prints the SSH command only while an owned simulated device has idle Manual control.
- Generated apps demonstrate pure decisions over SDK observations and ordinary host unit tests. Generated Elixir files are formatted.
- Prerequisite errors include Linux installation guidance and the macOS Linux-VM route.

### Fixed

- Clean device builds initialize the Nerves toolchain before compiling native dependencies; workstation binaries are not shipped to musl guests.
- Boot failures retain bounded, secret-free domain liveness diagnostics separately from the gateway status query.
- Invalid RTC time handling uses the `nerves_time` 0.4.14 fix.

Earlier component history is preserved in the immutable [firmware/v0.1.0](https://github.com/sid2baker/nerves_gate/tree/firmware/v0.1.0), [sim/v0.1.0](https://github.com/sid2baker/nerves_gate/tree/sim/v0.1.0) and [new/v0.1.1](https://github.com/sid2baker/nerves_gate/tree/new/v0.1.1) tags.
