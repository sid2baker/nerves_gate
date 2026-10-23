# Development

The repository root is the host-only developer platform, including the QEMU
simulator. `sdk/`, `firmware/` and `systems/` are separate projects, not umbrella
children. App developers use [ordinary app projects](app-development.md).

## Prerequisites

Linux x86_64 or aarch64 with QEMU 8.2+ (`user` and `stream` networking), fwup,
flock, mkfs.ext4, a C compiler, make, pkg-config, inotify-tools, squashfs-tools,
GNU coreutils and the libmnl/libnl headers needed by VintageNet.

```sh
# Ubuntu/Debian
sudo apt install build-essential git pkg-config libmnl-dev libnl-genl-3-dev qemu-system-x86 util-linux inotify-tools e2fsprogs squashfs-tools
# Fedora
sudo dnf install gcc make git pkgconf-pkg-config libmnl-devel libnl3-devel qemu-system-x86 util-linux inotify-tools e2fsprogs squashfs-tools
```

Install fwup from its [releases](https://github.com/fwup-home/fwup/releases). On
macOS, use a Linux VM such as arm64 Ubuntu in OrbStack. No root privileges, KVM,
bridges or workstation network changes are needed.

`mix setup` fetches locked dependencies, tailscaled and the prebuilt QEMU
system/toolchain, and checks these prerequisites. It neither builds firmware nor
boots devices. EC100 builds additionally need the published EC100 system artifact.

## Commands

| Command | Action |
| --- | --- |
| `mix setup` | Prepare tools and artifacts |
| `mix dev [APP_DIRECTORY] [--config PATH] [--port 4000]` | Start the workbench; optionally open an app |
| `mix dev.status`, `mix dev.stop` | Read or gracefully stop this checkout's session |
| `mix dev.ui [DEVICE] [--port 4001]` | Gateway UI with code reload against a running device |
| `mix app.new/test/package/install PATH`, `mix app.console` | [App operations](app-development.md) |
| `mix test.qemu --only ID [--device ID]` | Run scenarios on the running bench |
| `mix test.qemu --lifecycle start/stop/reset` | Explicit lifecycle action on that bench |
| `mix test.qemu --ci --only ID` | Boot and clean up a separate disposable bench |
| `mix test`, `mix test.sdk` | Root or SDK host tests |
| `mix format --force` | Format the root and subprojects |
| `mix ci` | All host checks and tests; no devices |
| `mix release.check TAG` | Read-only release validation |

The user owns the `mix dev` session. Agents must not start, stop or reset it, boot
its devices, or run `--ci` benches without authorization.

## Workbench and simulator

`mix dev` serves localhost:4000 and supervises a separate simulator BEAM. The
default bench is `priv/simulator/simulator.exs` with two devices;
`priv/simulator/tailnet.exs` adds [real Tailscale](tailnet-ci.md). Use
`--config PATH` for another trusted bench file.

Devices stay stopped until an explicit Start, which builds local firmware when
selected and creates disposable disks. Stop keeps disks; Reset erases them. After
device-code changes, Reset and Start. `Simulator.QemuTests` admits every
lifecycle change, fault, installation and scenario run; UI button state is only
presentation.

The simulator owns QEMU processes, QMP sockets, disks and Ethernet relays. Each
device has private socket networks; libslirp provides real traffic without host
networking changes. `_build/qemu-dev/session.lock` is held with flock until
cleanup finishes: never delete it to bypass ownership.

Device builds and user apps run in separate, supervised OS processes. Repository
host checks for `sdk/` and `firmware/` run in-VM through `Mix.Project.in_project/4`,
never with a device target. Shared dependencies are locked identically in the root
and firmware; update them deliberately with `mix deps.update` and keep
`--check-locked`.

## Scenarios

UI, CLI and CI share the modules in `lib/simulator/scenarios/`. Extend them for
hardware-facing behaviour instead of adding fake backends. Independent devices can
run concurrently; `devices: :all` reserves the whole bench and `fresh_disk`
scenarios own disposable state. `tailscale_auth` is opt-in.

Host tests cover pure firmware policy and codecs, workbench and app tooling,
discovery and release contracts. Firmware's Credo, Dialyzer, Reach and clone
checks run in root `mix ci`.

## Assets

Both UIs share firmware assets; Tailwind scans `firmware/lib/` and root `lib/`.
After template or style changes:

```sh
cd firmware
NERVES_GATE_LOCAL_DEPS=1 mix assets.build
```

Commit `firmware/priv/static/assets/` with the sources.

## Diagnostics and limits

- Bench diagnostics are in `_build/qemu-tests/<session>/<device>/`; boot failures
  leave `console-*.log`, `qemu.log` and `boot.log`.
- Never copy login URLs, cookies, CSRF tokens, keys or VM identity disks into logs,
  issues or artifacts.
- A timed-out state-changing request has an unknown outcome: inspect before retrying.
- Target dependencies previously compiled for the host need a clean target build.

## System artifacts

Files under `systems/` are artifact fingerprint inputs: changing them requires a
new system version. See [system releases](releases.md#systems).
