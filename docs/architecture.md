# Architecture

Nerves Gate has three application projects and two Nerves system projects, not an
umbrella. Device domains own commands, admission, deadlines and persistence.
EC100 and QEMU run the same application with different board profiles and target
binaries. The workstation runs the developer workbench and owns disposable QEMU
hardware; it does not run the device domains.

This page describes the current implementation. Proposed changes and tradeoffs
are in the [architecture review](architecture-review.md).

## Projects and dependencies

| Project | OTP application | Build/runtime role | Version |
| --- | --- | --- | --- |
| Root | `:nerves_gate_dev` | Host tooling, workbench and simulator | Root `VERSION` |
| `firmware/` | `:nerves_gate` | Host-compiled helpers/checks; EC100 or QEMU device runtime | Root `VERSION` |
| `sdk/` | `:nerves_gate_sdk` | Pure Elixir app contract and packaging; no application supervisor | `sdk/VERSION` |
| `systems/nerves_system_ec100/` | `:nerves_system_ec100` | ARM Linux, toolchain, boot and board support | System `VERSION` |
| `systems/nerves_system_ec100_qemu/` | `:nerves_system_ec100_qemu` | x86_64/musl Linux, toolchain and QEMU support | System `VERSION` |

```text
root (always host) ──path──→ sdk
                  └─path──→ firmware (host, runtime: false) ──path──→ sdk

firmware (ec100/x86_64) ──→ selected system source + fingerprinted artifact
```

Each project keeps its own Mix configuration, lockfile and build directory.
Root and firmware shared dependencies must have matching locks. Device builds
normally resolve immutable system Git tags; internal local builds select the
checkout's system sources. Only the SDK is published on Hex; see
[releases](releases.md).

`runtime: false` prevents automatic firmware application startup, **not compilation
or host code reuse**. The workbench uses firmware components/layouts,
`Projection`, `Status`, `NetworkStatus` and `Observations`. USB factory reconnection
also uses `NervesGate.Linux.Netlink`. The explicit session additionally starts
selected services through `NervesGate.Application`, as described below. The
firmware dependency is therefore not just a convenient source directory.

## Source map

| Path | Responsibility |
| --- | --- |
| `firmware/lib/nerves_gate.ex` | Administrative commands, direct status and subscriptions |
| `firmware/lib/nerves_gate/` | Device domains, adapters, projection, SDK backend, storage and apps |
| `firmware/lib/nerves_gate_web/` | Gateway endpoint, LiveViews and shared components |
| `firmware/config/` | Board profiles, device services and host-only checks/assets |
| `sdk/lib/nerves_gate_sdk/` | Typed app API, backend behaviour and package validation |
| `lib/dev/` | Sessions, app projects, discovery, builds, updates, provisioning and release checks |
| `lib/dev_web/`, `config/`, `priv/dev/` | Workbench UI, CLI API, host config and launch scripts |
| `lib/simulator.ex`, `lib/simulator/` | QEMU lifecycle, virtual hardware and scenario admission |
| `lib/dev/scenarios/`, `lib/dev/scenarios.ex` | Portable device/SDK scenarios and requirement checks |
| `lib/dev/test_device.ex`, `lib/dev/test_fixture.ex` | Bounded target access and explicitly owned bench controls |
| `lib/simulator/scenarios/` | QEMU-specific integration scenarios |
| `priv/simulator/`, `priv/templates/` | Trusted bench configs/scripts and ordinary SDK app scaffolding |
| `test/`, `firmware/test/unit/`, `sdk/test/` | Host/tooling and shared UI tests, firmware unit tests, SDK tests |
| `systems/` | Nerves system artifact inputs, independently versioned |

## Host mode and the simulator

### Session processes

[`Dev.Launcher`](../lib/dev/launcher.ex) owns the launch chain under `flock` and
MuonTrap. The lock lasts through child cleanup; never unlink it to bypass
ownership. The host launcher runs a workbench session BEAM, which supervises a
private loopback EPMD and a separate simulator BEAM.

Inside the workbench session:

```text
Dev.Supervisor (:nerves_gate_dev, one_for_one)
├─ Dev.Tasks
├─ Dev.Applications
├─ Dev.Discovery
└─ Dev.Operations

NervesGate.Supervisor (:nerves_gate, rest_for_one)
├─ NervesGate.PubSub
├─ Simulator.QemuTests
└─ DevWeb.Endpoint (configured under :nerves_gate_dev)

owned simulator BEAM
└─ Simulator → per-device owners → QEMU, disks, QMP and Ethernet relays
```

This is the actual wiring in [`priv/dev/session.exs`](../priv/dev/session.exs):
root configuration defaults `:nerves_gate, :services` to `[]`, then the explicit
session replaces it with `[Simulator.QemuTests, DevWeb.Endpoint]` and starts both
applications. `NervesGate.Application` always prepends PubSub. There is no local
gateway endpoint, VintageNet service or workstation Tailscale daemon. Host native
networking dependencies compile for types/helpers but their device services do
not start.

The workbench listens on loopback and on a private Unix HTTP socket used by CLI
commands. The session initiates distribution connections without an inbound UI
node listener; the simulator uses a hidden node and private management forwards.
Starting the session boots no devices. An explicit authorized Start builds the
selected local firmware if needed and starts the configured disposable devices.

### Admission and hardware ownership

`Dev.Operations` serializes workbench operations such as builds, app commands and
physical firmware reviews/updates. `Simulator.QemuTests` separately owns QEMU
admission and per-device reservations for UI, CLI and CI. They protect different
resources; UI button state is not admission.

Independent devices can run concurrently. A `devices: :all` scenario reserves the
whole bench; installs, manual controls and lifecycle/configuration changes also
participate in admission. Reservations remain held until the worker exits, not
merely until it reports a result.

[`Simulator.Device`](../lib/simulator/device.ex) owns its QEMU process, disks,
QMP connection and network supervisor. Scenario and UI workers receive controlled
handles, not ownership of those resources. QMP operations verify the supervised
process relationship. Uncertain control outcomes block further controls,
including cleanup, until explicit recovery; they are not retried automatically.

The virtual LAN is real Ethernet over private Unix sockets with libslirp Internet
access. A separate management path bypasses injected LAN faults. No host bridge,
VPN or routing changes are required. QEMU has separate system and application-SD
disks. Stop preserves them; Reset erases them and invalidates the prepared build.
Fresh-disk scenarios and failed runs use the runner's disposable-state recovery.
See [development](development.md#workbench-and-simulator).

## Board configuration

Each target declares wiring in `:nerves_gate, :board`:
`firmware/config/ec100.exs` for EC100 and `x86_64.exs` for owned QEMU, not arbitrary
PCs. `NervesGate.Board` supplies modem, bus, indicator, recovery and storage
adapters/paths. QEMU leaves unsupported EC100 peripherals unavailable; it does
not emulate them with fake application backends.

The BSP owns drivers, device trees, boot and Linux device naming. Board config
selects hardware; domains own policy. The current network model has two LAN
ports. EM300 and its three-port layout remain future work.

## Ownership and supervision

| Owner | Responsibility |
| --- | --- |
| VintageNet | Interfaces, saved network settings, connectivity, DNS and routes |
| Tailscale | Identity, preferences, enrollment and VPN routes |
| Network | Admission, trials, USB auto-save, SIM commissioning/PIN storage, deadlines and rollback |
| Remote | Serialized bounded daemon operations and sanitized metadata |
| Equipment | Neighbors, scoped labels and scan observations |
| Indicators | LED/button policy, identification and recovery |
| Buses | Diagnostics, CAN subscriptions and exclusive RS485 claims; caller lifetime owns SDK resources |
| SSH | Public-key validation, persistence and authentication |
| Storage | SD detection, commissioning, mounting and formatting |
| Apps | Trusted OTP app admission, lifecycle and version selection; gates destructive storage changes |
| ProjectionServer | Sanitized UI read model, not command coordination |
| SDKBackend | Translation into the separate typed application contract |
| LiveView | Drafts, presentation, subscriptions and command submission |

On devices, `nerves_runtime` initializes writable data and cellular INPUT
protection before networking and data users start. Dependencies supervise
VintageNet, tailscaled and Alarmist. The `rest_for_one` children of
`NervesGate.Supervisor` are ordered as follows:

```text
PubSub → Network.Vintage → workflow PropertyTable → persistent Settings PropertyTable
       → SSH → Network → Remote → Equipment → Indicators → Buses → AppTasks
       → Storage → Apps → ProjectionServer → SDKBackend → gateway Endpoint
```

See [`firmware/config/firmware.exs`](../firmware/config/firmware.exs) and
[`NervesGate.Application`](../firmware/lib/nerves_gate/application.ex). An earlier
child's failure restarts later children. The device application is `transient`:
an exhausted restart limit stops the BEAM and erlinit reboots the device. The
host session's explicitly selected services are a different tree, not this list.

Workers are linked and bounded; domains stop and join owned workers before
restoration or new work. Network trials, scans and sharing reply after completion;
cellular commissioning and Remote acknowledge acceptance and report completion
in status. A caller timeout means **unknown outcome**, not cancellation or
permission to replay. UI availability never replaces backend validation.

## Data flow

The administrative API, UI read model, application SDK and workstation CLI API
are distinct contracts:

```text
gateway LiveView / IEx → NervesGate command → domain admission → worker / adapter
NervesGate.status     → independent domain reads → Status.build

subsystem observations → ProjectionServer → sanitized replacements → LiveView
trusted app → NervesGateSDK → SDKBackend / Buses → typed values, events and I/O
workstation CLI → private workbench HTTP API → Dev / QemuTests ownership
```

`NervesGate.status/1` is neither atomic nor a query of the projection cache.
Commands return their result without a follow-up status read. Cross-domain
administrative commands enter through the [facade](action-api.md).

### UI projection

[`ProjectionServer`](../firmware/lib/nerves_gate/projection_server.ex) coalesces
observation changes for 20 ms, reads dirty domains and emits changed sanitized
inputs as `{:replace, domain, snapshot}`. Property notifications are invalidation
hints, not a command/event log. Subscription registers the caller before returning
`{:ok, server_pid, projection}`; subsequent operations come from that same owner.

[`Projection`](../firmware/lib/nerves_gate/projection.ex) and
[`Status`](../firmware/lib/nerves_gate/status.ex) derive the view on devices and
clients. [`Observations`](../firmware/lib/nerves_gate_web/observations.ex) monitors
the source, ignores replaced instances, shows unavailable on loss and resubscribes
with a fresh snapshot. Drafts stay separate. Private login URLs and cookies never
enter this stream.

The gateway uses local services. The workbench's **simulated-device page** uses
an explicit remote node and this same stream. Physical-device pages instead show
bounded discovery results and explicitly requested verified-SSH identity reads;
they are not live projection subscriptions. The remote backend remains needed
even though the workstation no longer serves a gateway UI.

### Applications and SDK

Apps are trusted, same-BEAM OTP code, **not a sandbox**. The SDK is their supported
contract, not a security barrier against arbitrary Elixir. It exposes typed
observations/events and process-owned bus I/O, not firmware status maps or
administrative network, SSH, firmware or recovery commands. Buses admits SDK I/O
from the actual caller so owner death releases claims/subscriptions.

Host packaging and device installation share the SDK's `.ez` validation. Private
OTP dependencies can be bundled, platform dependencies cannot; packaging is not
cross-compilation, a dependency solver or a hot-code upgrade service. Installation
does not start an app. Upgrades stop/start cold, run bounded health checks and
restore the prior selection on failure. Ordinary app callbacks still execute in
the shared runtime. See [applications](applications.md).

## Persistence and recovery

| Owner/store | Durable state |
| --- | --- |
| VintageNet | Confirmed interface settings |
| Tailscale | Device identity and preferences |
| Settings PropertyTable | Small device-local settings, including commissioned SIM PIN |
| Equipment / SSH | Scoped labels / authorized public keys |
| Apps: `/data/nerves_gate/apps.term` | Selected/previous versions and enabled state |
| Application SD: `/mnt/apps` | App code archives and app data |

Both targets require writable ext4 data before starting data users. Unreadable
saved network settings fail closed. Trials and monotonic deadlines live in RAM;
confirmation saves interfaces through VintageNet. **Multi-interface saves are not
transactional**; see [saving and rollback](networking.md#saving-and-rollback).
Startup sets default-deny IPv4 forwarding before enabling forwarding.

Card insertion never formats media. Storage commissioning requires an explicit
operation, and Apps checks admission before destructive changes. Uninstall keeps
app data; application rollback does not roll back that data. See
[storage](applications.md) and [reset safety](indicators.md#recovery).

## Fault reporting

Domains publish fixed sanitized conditions through SASL to Alarmist; named
instances scope alarms. Restore/recovery failures are immediate errors;
availability faults warn after two continuous seconds and clear on observed
recovery. Unknown stays unknown. Alarms never admit commands or trigger remedies.
See [LED policy](indicators.md#leds).

## Build, test and release boundaries

Root host checks enter the SDK and firmware through `Mix.Project.in_project/4`.
The helper restores Mix env/target, project, code path, compiler options,
environment variables and firmware app config, and stops a newly started subsystem
app. This is **not whole-VM isolation**: loaded modules and other application state
can survive. `Dev.configure/0` merges root config; it does not delete every
unrelated application setting. Root checks reload their configuration and compile
last. See [`mix.exs`](../mix.exs).

`mix setup` prepares locked dependencies, the checksum-pinned QEMU tailscaled
binary, Nerves artifacts and host tools; it does not compile device firmware or
boot devices. Its limited target-project entries fetch dependencies and initialize
Nerves, never compile target application code in the host VM.

Device firmware and external user-app builds use isolated supervised OS
processes. [`Dev.Builds`](../lib/dev/builds.ex) builds shared Volt assets on the
host **before** target packaging. Workbench and gateway share one asset definition
and tracked output; devices only serve it. Host and target native ports must not
be mixed. See [development](development.md#assets) and [CI](ci.md).

Host tests cover policy/codecs, SDK packaging, gateway rendering/security and
workbench contracts. Real I/O/recovery checks use the shared scenario runner:
portable cases declare device and fixture requirements; QEMU-specific cases stay
in `lib/simulator/scenarios/`. Requirements are checked before preparation.
Unsupported resources skip; missing declared hardware, unreachable devices and
broken controls fail. An entirely skipped run is not a pass. Only the owned QEMU
fixture is supplied; no automatic physical-device test attachment exists.
Firmware's `.reach.exs` checks device/Web call boundaries and pure status/policy
code; it is not a complete root-project dependency policy.

Routine CI runs host checks, a target build/native-port check and external-app
packaging, but boots no devices. QEMU integration is explicit. SDK/platform
publishing and fingerprinted system artifacts have separate workflows and version
rules; publishing credentials do not belong in the workbench. See
[CI](ci.md) and [releases](releases.md).

## Trust and physical operations

The gateway currently has **no user sign-in** and listens on all IPv4 interfaces.
Cellular INPUT protection, CSRF/session checks and a strict CSP do not authenticate
LAN/VPN users. Ethernet and VPN exposure must be limited to trusted networks;
see [HTTP exposure](networking.md#local-recovery-and-http-exposure).

Discovery advertisements are unverified public metadata, not authentication or
permission to update a device. A physical SSH update snapshots the image, verifies
the known host and device identity, requires explicit confirmation and rechecks
identity before upload. Acceptance is not proof of a healthy reboot. Destructive
USB provisioning has a separate review/confirmation and verified-write engine;
its RAM transport review is not a disk write. Reconnection is read-only and never
replays flashing. See [firmware updates](firmware-updates.md).

The workstation and trusted apps are privileged participants. Keep credentials,
private login URLs, distribution cookies and VM identity disks out of read models,
diagnostics and uploaded artifacts. Never attach simulator controls to arbitrary
VMs or physical gateways.
