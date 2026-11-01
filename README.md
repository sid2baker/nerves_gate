# Nerves Gate

Nerves firmware for EC100 and EM300 gateways and the developer platform around
them. Both expose the same foundation: commission Internet access, enroll remote
access, inspect available hardware and extend it with explicitly enabled plugins.
Different board resources do not mean different platform APIs or invented hardware
parity. See the [shared platform contract](docs/architecture.md#shared-platform-contract).

The same application runs in disposable QEMU devices, with board-specific firmware
builds. Trusted pure-BEAM plugins use ordinary libraries and the small
[Nerves Gate SDK](sdk/README.md).

## Quick start

Linux x86_64 or aarch64 (a Linux VM on macOS works), with the
[host prerequisites](docs/development.md#prerequisites):

```sh
mise install   # Elixir 1.20, OTP 29
mix setup      # dependencies, tools and prebuilt QEMU system; boots nothing
mix dev        # workbench at http://localhost:4000
```

Simulated devices stay stopped until you start them under **Develop → Firmware**.
QEMU devices need a [prepared management network](docs/qemu-management-network.md).
Nothing flashes physical hardware unless you explicitly confirm it.

## Plugins

`plugins/selection.exs` selects independent OTP projects for firmware. The initial
selection contains `tailnet_subrouter`, Modbus TCP/RTU using `yamodbus`, and the
experimental [IOTRouter expansion driver](plugins/iotrouter_expansion/README.md).
Plugins and their equipment transports start only through explicit controls.
Their private pure-BEAM libraries are bundled with them; SDK/LiveView stay shared.

```sh
mix firmware x86_64    # build assets, selected plugins and firmware; boots nothing
mix firmware ec100
mix firmware em300     # requires the locally built, unpublished system artifact
```

After an explicitly authorized deployment, use **Plugins** to start/configure them.
Discovery/startup does not connect equipment or enable sharing. There is no device
store or dependency download. See [plugin development](docs/plugin-development.md).

## Working on the platform

```sh
mix format --force
mix check                                    # pre-commit host checks; no devices
mix scenario.run sdk --device gateway_a       # against your running mix dev
```

| Path | Contents |
| --- | --- |
| `lib/workbench/`, `lib/workbench_web/` | Workbench, gateway directory, plugin tools, builds, updates and release checks |
| `lib/simulator/` | Owned QEMU devices and private virtual networking |
| `lib/scenarios/` | One scenario catalogue/runner, device access and owned-QEMU checks |
| `firmware/` | Device runtime and gateway UI (separate Nerves project) |
| `sdk/` | Small plugin integration contract and packaging (separately versioned, published on Hex) |
| `plugins/` | Firmware selection, subnet-router and Modbus TCP/RTU projects |
| `systems/` | Independent EC100, EM300 and owned-QEMU Nerves systems |

Read [development](docs/development.md), [architecture](docs/architecture.md),
[CI](docs/ci.md), [releases](docs/releases.md) and the [changelog](CHANGELOG.md).

## Device documentation

- [Public API](docs/action-api.md)
- [Networking and recovery](docs/networking.md)
- [Firmware builds and updates](docs/firmware-updates.md)
- [Plugin runtime and storage](docs/plugins.md)
- [Hardware resources and plugin assignments](docs/hardware.md)
- [LEDs and button](docs/indicators.md)
- [Gateway and workbench UI](docs/ui.md)

Apache-2.0. See [LICENSE](LICENSE).
