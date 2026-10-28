# Development

The repository root is the host-only developer platform, including the QEMU
simulator. `sdk/`, `firmware/` and `systems/` are separate projects, not umbrella
children. Plugin developers use [ordinary plugin projects](plugin-development.md).

## Dev-device inspection from Pi

`mix dev` starts a uniquely named hidden node. Its supervised `Workbench.Gateways`
automatically connects known LAN/Tailnet/manual gateways and running owned QEMU
gateways with `mycookie`, verifies firmware identity and tracks reconnects. It
never boots devices or opens equipment connections. **Devices** shows the same directory.

Reload Pi resources, then use the `dev-environment` executable skill: call
`Workbench.Skill.DevEnvironment.attach("/absolute/path/to/nerves_gate")` through
`elixir_eval` with target `bridge`. It reads this checkout's
`_build/workbench/session.json`, verifies the remote project root and session ID,
and points pi-elixir's runtime attachment at that node. Use target `runtime` for
`Workbench.DeviceInspection.devices/0`, then `identity/1`, `status/1`, `plugins/1`,
`hardware/1` and bounded sanitized `logs/2` on an explicitly selected directory node.
Call `attach/1` again before device operations and after the Workbench restarts;
Pi itself does not need a restart. Inspection does not start another node or
connection loop. Use the project target for source work, not device inspection.

## Firmware updates from Pi

After explicit operator authorization, the `firmware-update` executable skill calls
`Workbench.Jobs.review_firmware(node, firmware_path)` in the attached Workbench.
The user-owned `mix dev` must be running. Show the completed review to the user;
only after confirmation call `Workbench.Jobs.confirm_firmware(token, address)`.
Review checks the exact image, saved plugin artifacts, identity, health and SSH
trust. Confirmation consumes the review once, uploads over SSH and verifies a new
healthy boot over distribution. It never selects or starts plugins.
Errors or timeouts require inspection, not automatic replay. It does not build,
bump versions, erase metadata or bypass SSH host-key verification.

## Prerequisites

Linux x86_64 or aarch64 with QEMU 8.2+ (`user` and `stream` networking), fwup,
flock, mkfs.ext4, a C compiler, make, pkg-config, inotify-tools, squashfs-tools,
socat (disposable RTU test PTYs), GNU coreutils and the libmnl/libnl headers needed by VintageNet.

```sh
# Ubuntu/Debian
sudo apt install build-essential git pkg-config libmnl-dev libnl-genl-3-dev qemu-system-x86 util-linux inotify-tools e2fsprogs squashfs-tools socat
# Fedora
sudo dnf install gcc make git pkgconf-pkg-config libmnl-devel libnl3-devel qemu-system-x86 util-linux inotify-tools e2fsprogs squashfs-tools socat
```

Install fwup from its [releases](https://github.com/fwup-home/fwup/releases). On
macOS, use a Linux VM such as arm64 Ubuntu in OrbStack. QEMU management requires
explicitly prepared private bridge/TAP hardware and `iproute2` (Fedora: `iproute`).
QEMU itself stays unprivileged; no KVM, physical LAN bridge or VPN changes are needed.
See [management network](qemu-management-network.md) for privileges and cleanup.

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
| `mix firmware [x86_64 \| ec100] [--env dev \| prod]` | Build assets and selected pure-BEAM plugins on the host, then firmware in an isolated process; never boots a device |
| `mix dev [PLUGIN_DIRECTORY] [--config PATH] [--port 4000]` | Start the workbench; optionally open a plugin project |
| `mix dev.status`, `mix dev.stop` | Read (including the attachable node) or gracefully stop this checkout's session |
| `mix dev.network setup --subnet PRIVATE/24 [--config PATH]` | Explicitly prepare private QEMU bridge/TAPs; requires approved sudo access |
| `mix dev.network cleanup` | Remove only recorded network resources after stopping the session |
| `mix plugin.new/test/package/install PATH` | [Plugin project operations](plugin-development.md) |
| `mix test.qemu --only ID [--device ID]` | Run scenarios on the running bench |
| `mix test.qemu --lifecycle start/stop/reset` | Explicit lifecycle action on that bench |
| `mix test.qemu --ci --only ID` | Boot and clean up a separate disposable bench |
| `mix test`, `mix test.sdk` | Root or SDK host tests |
| `mix format --force` | Format the root and subprojects |
| `mix check` | Required pre-commit host gate, including firmware lint/clone/architecture, generated-plugin and plugin tests; no dialyzer/devices |
| `mix ci` | Same host gate plus firmware dialyzer; operator-owned, no devices |
| `mix release.check TAG` | Read-only release validation |

The user owns the `mix dev` session. Agents must not start, stop or reset it, boot
its devices, or run `--ci` benches without authorization.

## Workbench and simulator

`mix dev` serves localhost:4000 and locally supervises the simulator hardware owner. The
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

The simulator owns QEMU processes, QMP sockets, disks and Ethernet relays. The
private socket LANs/libslirp still provide simulated Internet and fault injection.
Protected eth2 uses the explicitly prepared bridge/TAP network. Firmware receives
its static management IP through the virtual disk serial, starts its own ordinary
EPMD and exposes services directly at that IP. Only USB recovery uses a host forward.
Prepare the network before starting the session if QEMU devices are needed; physical
inspection works without prepared QEMU networking. Network cleanup is explicit and
never happens on application startup. `_build/workbench/session.lock` is held with flock until
cleanup finishes: never delete it to bypass ownership. Session metadata advertises the hidden node, session identity and browser port in
that directory; simulator disks/diagnostics live under `_build/simulator/`.
Mix tasks attach over distribution and call ordinary functions; there is no HTTP
control API or CLI socket. Internal session inputs are `WORKBENCH_SESSION_ID`,
`WORKBENCH_DIR`, `WORKBENCH_HTTP_PORT`,
`WORKBENCH_CI` and `WORKBENCH_SCENARIO`. `QEMU_SIM_CONFIG` selects the simulator configuration; diagnostics use the session's
owned simulator directory. The launcher manages these inputs; ordinary plugin development
needs none of them.

Device builds and plugin projects run in separate, supervised OS processes. Repository
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
a separate admission owner, `Workbench.Jobs`, which also reserves lifecycle and
session shutdown until each job worker exits.

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
name. The only supplied **control** fixture is owned QEMU. Physical checks have
their own explicit catalogue, `Scenarios.physical/0`, and run individually through
Jobs on a verified connected gateway. Readiness uses distribution observations;
Ethernet/4G failover and button-reboot checks are operator-attended procedures.
Keep management independent from the link being tested. The human restores cables
and controls the button; the Workbench sends no physical switch or reboot command.
A failed/cancelled check is not permission to repeat an action. Connectivity and
the `:physical` requirement do not grant fixture-control authority.

Add physical checks deliberately at this admission boundary; do not send the
whole QEMU catalogue to a discovered board. No physical procedures or hardware
tests are run by root tests/CI. Host tests cover pure phase/identity/confirmation
policies and rendered safeguards, not a second hardware-mock backend.

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
plugin tooling, gateway directory, release contracts and shared UI integration. Root `mix ci`
enters firmware natively and runs both firmware directories once; moved gateway
tests are not duplicated at the root. Firmware's Credo, Dialyzer, Reach and clone
checks also run in root `mix ci`. Run `mix check` before commits; it exercises the
same host paths except dialyzer and includes SDK, generated-plugin and plugin tests.
See [CI scope](ci.md#local-gates-and-project-scope). Split workbench page tests keep
workspace-specific assertions separate, sharing only pure view fixtures.

## Assets

Both UIs share assets defined in `firmware/config/assets.exs`; Tailwind scans
`firmware/lib/` and root `lib/`. Volt handles workbench asset changes automatically
while `mix dev` is running.

Run firmware builds from the repository root, for example `mix firmware ec100`
or `mix firmware ec100 --env prod`. The workbench's Build action and local QEMU
builds use the same pipeline: compile assets on the host, then run the target
firmware build in an isolated process. Asset failures stop packaging. Volt never
runs on the device. No separate asset command or environment flag is required.
`mix check` and `mix ci` also build assets without building firmware or starting devices.

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
