# Development

The root is a host-only developer platform. `sdk/`, `sim/`, `firmware/` and
`systems/` are independent projects, not umbrella children. App developers use
[ordinary app projects](app-development.md) with the same workbench.

## Prerequisites

Use Linux x86_64 or aarch64, QEMU 8.2+ with `user` and `stream` networking, fwup,
flock, mkfs.ext4, a C compiler, make, pkg-config, inotify-tools, squashfs-tools and
GNU coreutils (`timeout`, used for bounded local firmware metadata reads).
VintageNet host compilation also requires libmnl/libnl headers.

Ubuntu/Debian:

```sh
sudo apt install build-essential git pkg-config libmnl-dev libnl-genl-3-dev qemu-system-x86 util-linux inotify-tools e2fsprogs squashfs-tools
```

Fedora:

```sh
sudo dnf install gcc make git pkgconf-pkg-config libmnl-devel libnl3-devel qemu-system-x86 util-linux inotify-tools e2fsprogs squashfs-tools
```

Install fwup from its [releases](https://github.com/fwup-home/fwup/releases).
On macOS, use a Linux VM, for example arm64 Ubuntu in OrbStack. No workstation
network changes, bridges, TAP devices, root privileges or KVM are required.

`mise.toml` pins Elixir 1.20 and OTP 29. `mix setup` fetches locked dependencies,
tailscaled and prebuilt QEMU system/toolchain artifacts, and checks prerequisites.
It does not compile device firmware or boot devices. The first explicit firmware
build takes minutes. The EC100 system artifact is separate; building EC100 needs
that system's published artifact or an explicit local system build.

## Commands

Run from the checkout:

| Command | Action |
| --- | --- |
| `mix setup` | Prepare tools/artifacts without booting devices |
| `mix dev [APP_DIRECTORY] [--port 4000]` | Start the workbench; optionally open an app |
| `mix dev.status` | Read this checkout's session identity/status |
| `mix dev.stop` | Graceful session stop; never kills an arbitrary PID |
| `mix dev.ui [DEVICE] [--port 4001]` | Reloadable gateway UI against a running device |
| `mix app.new PATH [--local-sdk]` | Create an independent SDK app |
| `mix app.test/package/install PATH`, `mix app.console` | [App operations](app-development.md) |
| `mix test.qemu --only ID [--device ID]` | Attach to the user's existing QEMU bench |
| `mix test.qemu --lifecycle start/stop/reset` | Explicit lifecycle action on that bench |
| `mix test.qemu --ci --only ID` | Boot and clean up an independent disposable bench |
| `mix test` | Root workbench/tool tests |
| `mix test.sdk`, `mix test.sim` | Independent host subsystem tests |
| `mix format --force` | Format the root and subsystems, excluding system fingerprints |
| `mix ci` | All host quality gates and tests; no devices |
| `mix release.check TAG` | Read-only release metadata/dependency validation |

The user owns their `mix dev` session. Agents must not start, stop or reset it,
boot devices, or run disposable integration benches without authorization.

## Workbench lifecycle

`mix dev` serves localhost:4000 and a private Unix socket at
`_build/qemu-dev/http.sock`. Devices remain stopped until an admitted Start.
Fresh Start builds local firmware when selected, creates disposable disks and
boots configured devices. Stop preserves disks; Reset explicitly erases them.
Device-code changes need Reset followed by Start. Faults, scenarios, installations
and lifecycle changes are admitted by `NervesGateSim.QemuTests`, not by UI button
availability.

Applications are opened or created on the Applications page; no solution manifest
is required. The Devices page lists both physical gateways and tagged simulated
devices; Simulator holds bench-wide wiring and lifecycle controls. LAN discovery
starts on the Devices page or explicit refresh and is read-only mDNS and never attaches a hardware driver to a found
gateway. Manual entries accept DNS names and IPv4 addresses. The workbench also
supports explicit EC100/QEMU builds and authenticated SSH firmware review/update;
see [firmware updates](firmware-updates.md) for confirmation and prerequisites. Existing non-advertising firmware needs an explicit known address.
The simulator default is `sim/priv/qemu/simulator.exs`, with two devices. A custom trusted data file can be
selected with `mix dev --config PATH` (paths are relative to the platform root).
Tailscale opt-in uses `sim/priv/qemu/tailnet.exs`.

The launcher holds `_build/qemu-dev/session.lock` with flock through child cleanup.
Never delete this file to bypass ownership. A stale metadata file is not evidence
of a running process. Shutdown waits for active work to finish and rejects
ambiguous session identities. Use the owning terminal if its API is unavailable.

## Process boundaries

The workbench supervises its simulator BEAM through MuonTrap. The simulator owns
QEMU children, QMP sockets, virtual disks and Ethernet relays. Scenarios and UI
workers never own those resources. Each device has an independent private socket
network; libslirp supplies real traffic without host networking changes.

Device builds always run in an isolated OS process with an explicit target.
Never call device-target compilation through native `Mix.Project.in_project/4`.
User apps also use isolated Mix processes, keeping their Hex SDK and code out
of the workbench VM. Host-only repository checks use native project contexts;
the root runs them before compiling/testing itself and restores environment,
code paths and application ownership on return.

Root, simulator and firmware locks agree on shared dependencies. Deliberately
update dependencies with `mix deps.update`, and keep `--check-locked`. The root
formatter reads subsystem formatter files directly rather than compiling each
project merely to format it.

## Scenarios

UI, CLI and CI share ordinary modules in `sim/scenarios/`, compiled by the root.
Extend them for real hardware-facing behaviour; do not introduce fake device
backends. Independent device runs can coexist; `devices: :all` reserves the entire
bench. `fresh_disk` scenarios own disposable state. Authenticated Tailscale is
opt-in; see [tailnet testing](tailnet-ci.md).

The suite covers network trials, recovery, faults, storage, SDK, apps, gateway
assets and the system contract. Host tests cover pure policy/codecs, application
creation/packaging and discovery projections, endpoint configuration and release contracts. Firmware's
`.reach.exs`, Credo, Dialyzer and clone checks run in root `mix ci`.

## Assets

Both UIs share firmware assets and components. Root development uses Volt; built
assets are served by devices and test-mode workbenches. Tailwind scans both
`firmware/lib/` and root `lib/`. After template/style changes:

```sh
cd firmware
NERVES_GATE_LOCAL_DEPS=1 mix assets.build
```

Commit `firmware/priv/static/assets/` with the sources.

## Diagnostics and limits

- QEMU bench diagnostics: `_build/qemu-tests/<session>/<device>/`.
- Build progress: terminal and workbench operation/lifecycle output.
- Boot failure: `console-*.log`, `qemu.log` and bounded `boot.log` diagnostics.
- Never copy private login URLs, cookies, CSRF tokens, VM identity disks or keys
  into logs, issues or uploaded artifacts.
- A timed-out state-changing request has unknown outcome: inspect before retrying.
- Previously host-compiled target dependencies need a clean target build. CI
  verifies native ports use the musl loader; it never weakens the lock or deadline.

## System artifacts

System source files are immutable artifact fingerprint inputs. Never reuse a
published version after changing them. See [releases](releases.md#systems) for
read-only planning, source checks and protected CI publication.
