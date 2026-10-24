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
boots devices. QEMU's amd64 daemon is installed by `Tailscaled.Installer` before
target compilation, with an explicit Tailscale 1.104.1 archive checksum and cache
under `firmware/_build/setup/`. The EC100's qualified ARM daemon is unchanged;
EC100 builds additionally need the published EC100 system artifact.

## Commands

| Command | Action |
| --- | --- |
| `mix setup` | Prepare tools and artifacts |
| `mix firmware [x86_64 \| ec100] [--env dev \| prod]` | Build assets on the host, then firmware in an isolated process; never boots a device |
| `mix dev [APP_DIRECTORY] [--config PATH] [--port 4000]` | Start the workbench; optionally open an app |
| `mix dev.status`, `mix dev.stop` | Read or gracefully stop this checkout's session |
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
device-code changes, including gateway Elixir/HEEx, rebuild firmware, Reset and
Start. Open the device's gateway link to use its UI; the workstation serves only
the workbench. `Scenarios.Runner` admits every lifecycle change, fault,
installation and scenario run; UI button state is only presentation. Host tools
and guests must come from the same checkout; coordinate session replacement and
disposable-device resets explicitly when updating incompatible firmware.

The simulator owns QEMU processes, QMP sockets, disks and Ethernet relays. Each
device has private socket networks; libslirp provides real traffic without host
networking changes. `_build/workbench/session.lock` is held with flock until
cleanup finishes: never delete it to bypass ownership. Session metadata and its
private CLI socket live in that directory; simulator disks/diagnostics live under
`_build/simulator/`. Internal session inputs are `WORKBENCH_SESSION_ID`,
`WORKBENCH_SESSION_DIR`, `WORKBENCH_HTTP_SOCKET`, `WORKBENCH_HTTP_PORT`,
`WORKBENCH_CI` and `WORKBENCH_SCENARIO`. `QEMU_SIM_CONFIG`/`QEMU_SIM_DIR` configure
the actual simulator. The launcher manages these inputs; ordinary app development
needs none of them.

Device builds and user apps run in separate, supervised OS processes. Repository
host checks for `sdk/` and `firmware/` run in-VM through `Mix.Project.in_project/4`;
only dependency fetching and Nerves artifact initialization may enter a device
target in that VM, never target application compilation. The helper restores
selected Mix/compiler/configuration state, not the entire VM. Root configuration
is merged on return; unrelated settings can remain without their services running.
See the [project and session map](architecture.md).

Shared dependencies are locked identically in the root and firmware; update them
deliberately with `mix deps.update` and keep `--check-locked`.

## Scenarios

UI, CLI and CI use the explicit `Scenarios` catalogue and `Scenarios.Runner`;
every case lives in `lib/scenarios/cases/`. Independent devices can run
concurrently; `devices: :all` reserves the whole bench and `fresh_disk` scenarios
own disposable state. `tailscale_auth` is opt-in. Global workbench operations have
a separate admission owner, `Workbench.Operations`.

Every case declares `requires: %{device: [...], fixture: [...]}`. Device resources
are `:ethernet`, `:cellular`, `:can` and `:rs485`; fixture capabilities describe
owned controls, not product hardware. QEMU-specific cases require `:qemu`.
`cable_loss` requires Ethernet and `:ethernet_link`: it discovers the configured
Internet port, checks link loss and typed SDK events, then restores the link.
Prepare a linked, addressed, separate Internet port and independent management
path. Read-only status/SDK cases need no fixture. QEMU-specific assertions are
`qemu_status`/`qemu_sdk`.

`Scenarios.run(module, %{device: target})` performs no default QEMU preparation.
Targets have `:node`, optional diagnostics `:dir` and optional
`fixture: {:qemu, owned_handle}`. The caller must already own/reserve the
authorized disposable target and manage cleanup. There is no configurable fixture
module, automatic discovery, physical attachment or grant of control from a node
name. The only supplied control fixture is owned QEMU.

Requirements are checked **before** preparation. Unsupported resources skip;
missing/unobserved declared hardware fails. A board without CAN skips a CAN case,
but a declared port that disappeared does not. Disabled/disconnected ports remain
supported; cases also check operating state. RPC/assertion/control failures are
failures, not skips. An entirely skipped run is not a pass.

`Scenarios.Device.rpc(device, module, function, args)` is bounded, explicit and
never retried. A lost transport reply blocks subsequent writes/controls and
cleanup until explicit recovery, because the guest may have accepted the command.
Read-only status polling is separate. Deliberate process faults live in
`Scenarios.Recovery`, which discovers children through owning supervisors. Keep
these controls out of the SDK and extend real scenarios, not fake backends.

Firmware host tests cover policy/codecs in `firmware/test/unit/` and gateway
rendering/socket security in `firmware/test/web/`. Root tests cover workbench and
app tooling, discovery, release contracts and shared UI integration. Root `mix ci`
enters firmware natively and runs both firmware directories once; moved gateway
tests are not duplicated at the root. Firmware's Credo, Dialyzer, Reach and clone
checks also run in root `mix ci`.

## Assets

Both UIs share assets defined in `firmware/config/assets.exs`; Tailwind scans
`firmware/lib/` and root `lib/`. Volt handles workbench asset changes automatically
while `mix dev` is running.

Run firmware builds from the repository root, for example `mix firmware ec100`
or `mix firmware ec100 --env prod`. The workbench's Build action and local QEMU
builds use the same pipeline: compile assets on the host, then run the target
firmware build in an isolated process. Asset failures stop packaging. Volt never
runs on the device. No separate asset command or environment flag is required.
`mix ci` also builds assets without building firmware or starting devices.

For an asset-only diagnostic build, firmware provides `mix assets.build`
(`volt.build --tailwind`); repository tooling enters that host project natively.
Include the resulting `firmware/priv/static/assets/` files with their sources.
`NERVES_GATE_LOCAL_DEPS` selects local system/BSP sources for internal device
builds; the build pipeline sets it automatically. It is not an asset setting.

## Diagnostics and limits

- Bench diagnostics are in `_build/simulator/<session>/<device>/`; boot failures
  leave `console-*.log`, `qemu.log` and `boot.log`.
- Never copy login URLs, cookies, CSRF tokens, keys or VM identity disks into logs,
  issues or artifacts.
- A timed-out state-changing request has an unknown outcome: inspect before retrying.
- Target dependencies previously compiled for the host need a clean target build.

## System artifacts

Files under `systems/` are artifact fingerprint inputs: changing them requires a
new system version. See [system releases](releases.md#systems).
