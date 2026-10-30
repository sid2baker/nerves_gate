# Development

The repository root is the host-only developer platform, including the QEMU
simulator. `sdk/`, `firmware/` and `systems/` are separate projects, not umbrella
children. Plugin developers use [ordinary plugin projects](plugin-development.md).

## Deferred tooling

Machine-readable JSON observation output and local artifact-baseline preflight
are not implemented. Device-side immutable-artifact review remains authoritative;
a missing local baseline must never be treated as proof of compatibility. These
optional improvements do not block automation dependency evaluation.

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

## Physical firmware updates

With the user-owned `mix dev` running, and after explicit operator authorization:

```sh
mix firmware.update nerves-gate.example.ts.net            # built EC100 image
mix firmware.update GATEWAY path/to/image.fw --sha256 SHA # non-interactive
```

`GATEWAY` is a connected gateway's address or node. The task prints read-only
gateway state (firmware, plugins, storage and saved network settings), reviews
the image through `Workbench.Jobs`, shows the review and asks for confirmation.
`--sha256` replaces the prompt and confirms only that exact reviewed image; use it
from Pi only after the user approved that SHA-256. After a verified update it
prints the state again so changes, such as plugins that need a new selection, are
visible. The `firmware-update` skill and gateway page use the same jobs. Review checks the exact image, saved plugin artifacts, identity, health and SSH
trust. Confirmation consumes the review once, uploads over SSH and verifies a new
healthy boot over distribution. It never selects or starts plugins.
Errors or timeouts require inspection, not automatic replay. It does not build,
bump versions, erase metadata or bypass SSH host-key verification.

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
| `mix dev.status`, `mix dev.doctor` | Read session identity, loaded protocol compatibility and prerequisites; doctor never repairs anything |
| `mix dev.stop` | Gracefully stop this checkout's idle session; excludes active jobs/runs |
| `mix dev.job [ID]` | Read current/recent Jobs and Runner outcomes; IDs include session and owner |
| `mix gateway.list` | Read the verified gateway directory, including target kind and owned simulator IDs |
| `mix gateway.inspect TARGET` | Bounded identity, status (including storage), plugins and hardware reads |
| `mix gateway.logs TARGET [--limit 1..100]` | Bounded sanitized warning-or-higher log snapshot; not streaming |
| `mix dev.network setup --subnet PRIVATE/24 [--config PATH]` | Explicitly prepare private QEMU bridge/TAPs; requires approved sudo access |
| `mix dev.network cleanup` | Remove only recorded network resources after stopping the session |
| `mix firmware.update GATEWAY [IMAGE] [--sha256 SHA]` | [Reviewed physical firmware update](#physical-firmware-updates) |
| `mix plugin.new/test/package PATH` | Standalone [plugin project operations](plugin-development.md); no session required |
| `mix plugin.install PATH --device TARGET` | Session Jobs workflow; owned QEMU installation or reviewed/confirmed physical installation |
| `mix simulator.start/stop` | Start/stop the running session's owned QEMU devices; stop preserves disks |
| `mix simulator.reset [--confirm]` | Erase every owned simulated device disk; prompts unless explicitly confirmed |
| `mix scenario.list` | Local catalogue, requirements and target kinds; no session or effects |
| `mix scenario.run ID --device TARGET` | Run an explicit case/target through Runner (QEMU) or Jobs (physical catalogue only) |
| `mix scenario.ci ID --device ID [--config PATH]` | Explicitly boot and clean up a separate disposable QEMU bench |
| `mix test`, `mix test.sdk` | Root or SDK host tests |
| `mix format --force` | Format the root and subprojects |
| `mix check` | Required pre-commit host gate, including firmware lint/clone/architecture, generated-plugin and plugin tests; no dialyzer/devices |
| `mix ci` | Same host gate plus firmware dialyzer; operator-owned, no devices |
| `mix release.check TAG` | Read-only release validation |

The user owns the `mix dev` session. Agents must not start, stop or reset it, boot
its devices, or run `scenario.ci` benches without authorization.

### Choosing an interface and observing completion

Standalone setup, build, format, host tests and plugin project commands need no
session. Gateway inspection, maintenance, simulator controls and scenario execution
attach to this checkout's running Workbench. Run `mix help TASK` for strict flags.
Targets are always explicit: a connected node/address or owned simulator ID from
`mix gateway.list`. There is no implicit first-device selection. `all` is an explicit
QEMU catalogue selection, never a collection of physical procedures.

Session commands verify canonical checkout root, session ID and protocol revision.
Mutation admission also compares loaded SDK/platform versions and a small explicit
manifest of protocol-defining source inputs captured at compilation/startup. This
is not general source freshness checking. Changes to those inputs require a
coordinated user-owned Workbench restart. Reads remain available for diagnostics.
No command automatically restarts a session or repairs host networking.

Jobs and Runner own their IDs and bounded in-memory histories independently. CLI
commands print the accepted ID and wait for completion; the UI shows the same IDs
and outcomes. Use `mix dev.job ID` after a client timeout. A timeout does not cancel
the worker, release reservations or authorize replay. If the admission reply was
lost, inspect `mix dev.job` and the target without resubmitting. `uncertain` means
unknown effects; further maintenance/control remains blocked as appropriate.
History is lost with its owner/session; a new session is not proof of safe retry.
An admission owner restarted inside the same session fails closed rather than
re-enabling writes after losing its history. Inspect targets and coordinate session
replacement; this does not authorize replay.

Use Mix workflows or UI for supported operations. Runtime tools attach through
`dev-environment` and read the verified directory via `Workbench.DeviceInspection`.
Raw `:erpc` is transport infrastructure, not a bypass for Jobs/Runner admission,
confirmation or physical authorization. Scenario code uses `Scenarios.Device.rpc/4`.
Subscriptions and SDK leases retain actual-calling-PID ownership; temporary RPC
workers never proxy those resources. Workbench exposes no general remote gateway
command facade or HTTP control API.

Only reviewed firmware/plugin/factory maintenance has a Workbench physical-write
path. Firmware confirmation consumes a target/image-bound review once; exact SHA
approval is not permission to retry an uncertain upload. Physical checks are
explicit operator-authorized cases, not automatically included in QEMU suites.

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
`cable_loss` requires Ethernet, owned QEMU and `:ethernet_link`: it discovers the
configured Internet port, checks link loss through typed SDK events received by
the managed fixture plugin (SDK subscriptions belong to managed plugin processes),
then restores the link. Prepare a linked, addressed, separate Internet port and
independent management path. Read-only status/SDK cases need no fixture. QEMU-specific assertions are
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
  leave `console-*.log`, `qemu.log` and `boot.log`. QEMU firmware also logs to its
  serial console, so `tail -f console-<boot>.log` follows a device's logs live; each
  boot keeps its own file across resets.
- Never copy login URLs, cookies, CSRF tokens, keys or VM identity disks into logs,
  issues or artifacts.
- A timed-out state-changing request has an unknown outcome: inspect before retrying.
- Target dependencies previously compiled for the host need a clean target build.

## System artifacts

Files under `systems/` are artifact fingerprint inputs: changing them requires a
new system version. See [system releases](releases.md#systems).
