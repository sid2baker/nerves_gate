# Nerves Gate

A developer platform and Nerves firmware for EC100 controllers. The same firmware
runs in disposable QEMU devices and on real gateways. Applications use the typed
[Nerves Gate SDK](sdk/README.md), not workstation hardware stand-ins.

## Start the developer platform

Use Linux x86_64 or aarch64 (including a Linux VM on macOS), with the
[host prerequisites](docs/development.md#prerequisites). `mise.toml` pins Elixir
1.20 and OTP 29. App developers use a supported platform release checkout;
maintainers work on source.

```sh
mise install
mix setup
mix dev
```

The workbench opens at http://localhost:4000 with every device stopped. Start,
stop, reset, wiring and scenario actions are explicit. Setup downloads the QEMU
system/toolchain; firmware is built locally when explicitly requested or when
starting fresh simulated devices. Nothing flashes physical hardware.

## Develop a solution

Keep your solution in its own repository, outside the platform checkout:

```sh
mix solution.new ../my_solution
mix app.new controller --solution ../my_solution
mix app.test --solution ../my_solution
mix app.package controller --solution ../my_solution
mix dev ../my_solution
```

A solution has `nerves_gate.exs` and independent Mix apps under `apps/`, not another
platform Mix project. Apps depend on the released SDK. Use `--local-sdk` when
creating a solution for SDK development. The workbench shows platform-version
mismatches, app operations and firmware build progress.

See [app development](docs/app-development.md) for storage commissioning,
installation, console access and the SSH-only real-gateway workflow.

## Work on the platform

```sh
mix format --force
mix ci                                     # host checks; no devices
mix test.qemu --only sdk --device gateway_a # user's running bench
```

Disposable integration benches are explicit: `mix test.qemu --ci --only sdk`.
They never attach to arbitrary VMs or physical devices. See
[development](docs/development.md) and [CI](docs/ci.md).

## Projects

| Path | Owner |
| --- | --- |
| Root `lib/dev/`, `lib/dev_web/` | Workbench, solution tools, builds and release checks |
| `sim/` | QEMU lifecycle, virtual hardware and shared scenario admission |
| `firmware/` | EC100/QEMU device runtime and gateway UI |
| `sdk/` | Independently versioned app contract and packaging, published on Hex |
| `systems/` | Nerves system sources and GitHub artifacts |

No umbrella or fake hardware backend. The platform, firmware and simulator share
`VERSION`; the SDK and systems keep independent versions. Platform releases are
GitHub tags/releases, not Hex packages. Previously published component packages
remain immutable. See [architecture](docs/architecture.md),
[releases](docs/releases.md) and the [changelog](CHANGELOG.md).

## Device documentation

- [Public commands](docs/action-api.md)
- [Networking and recovery](docs/networking.md)
- [Applications and storage](docs/applications.md)
- [CAN and RS485](docs/buses.md)
- [Indicators](docs/indicators.md)
- [Gateway and workbench UI](docs/ui.md)

Apache-2.0. See [LICENSE](LICENSE).
