# Nerves Gate

Nerves firmware for EC100 controllers and the developer platform around it. The
same application runs on real gateways and in disposable QEMU devices, with
board-specific firmware builds. Applications use the typed
[Nerves Gate SDK](sdk/README.md).

## Quick start

Linux x86_64 or aarch64 (a Linux VM on macOS works), with the
[host prerequisites](docs/development.md#prerequisites):

```sh
mise install   # Elixir 1.20, OTP 29
mix setup      # dependencies, tools and prebuilt QEMU system; boots nothing
mix dev        # workbench at http://localhost:4000
```

Simulated devices stay stopped until you start them on the Simulator page.
Nothing flashes physical hardware unless you explicitly confirm it.

## Applications

Apps are ordinary Mix projects in their own directories. Create or open them on
the Applications page, or:

```sh
mix app.new ../my_controller
mix app.test ../my_controller
mix app.package ../my_controller
```

See [app development](docs/app-development.md).

## Working on the platform

```sh
mix format --force
mix ci                                       # host checks; no devices
mix test.qemu --only sdk --device gateway_a  # against your running mix dev
```

| Path | Contents |
| --- | --- |
| `lib/dev/`, `lib/dev_web/` | Workbench, app tools, discovery, builds, updates and release checks |
| `lib/simulator/` | QEMU devices, virtual networking, scenarios and runner |
| `firmware/` | Device runtime and gateway UI (separate Nerves project) |
| `sdk/` | App contract and packaging (separately versioned, published on Hex) |
| `systems/` | EC100 and QEMU Nerves systems |

Read [development](docs/development.md), [architecture](docs/architecture.md),
the [architecture review and recommendations](docs/architecture-review.md),
[CI](docs/ci.md), [releases](docs/releases.md) and the [changelog](CHANGELOG.md).

## Device documentation

- [Public API](docs/action-api.md)
- [Networking and recovery](docs/networking.md)
- [Firmware builds and updates](docs/firmware-updates.md)
- [Applications and storage](docs/applications.md)
- [CAN and RS485](docs/buses.md)
- [LEDs and button](docs/indicators.md)
- [Gateway and workbench UI](docs/ui.md)

Apache-2.0. See [LICENSE](LICENSE).
