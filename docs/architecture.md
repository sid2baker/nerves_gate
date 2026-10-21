# Architecture

Device domains own commands, admission, deadlines and persistence. The gateway UI
reads a device-owned projection and submits commands through
[`NervesGate`](../firmware/lib/nerves_gate.ex). EC100 and QEMU run the same
firmware. Workstation UIs connect over Erlang distribution. Third-party OTP
applications run in the same BEAM and use only the SDK.

## Source map

| Path | Responsibility |
| --- | --- |
| `mix.exs` | Orchestration only: runs the independent projects natively |
| `firmware/lib/nerves_gate.ex` | Public commands, status and subscriptions |
| `firmware/lib/nerves_gate/` | Device domains, adapters, projection, SDK backend, storage and apps |
| `firmware/lib/nerves_gate_web/` | Gateway endpoint, LiveViews and components |
| `firmware/config/` | Firmware profiles; `host.exs` is for checks and assets only |
| `firmware/test/unit/` | Host tests of pure firmware behaviour |
| `sim/scenarios/` | Repository-only real-QEMU integration scenarios |
| `tools/` | Private release tooling and unit tests |
| `sdk/lib/nerves_gate_sdk/` | Application API, SDK structs, backend behaviour and package validation |
| `sim/lib/nerves_gate_sim/simulator.ex`, `simulator/` | QEMU lifecycle and owned virtual hardware |
| `sim/lib/nerves_gate_sim_web/` | Simulator endpoint, overview, device tests and CLI API |
| `sim/lib/nerves_gate_sim/qemu_tests.ex` | Shared runner and device reservations |
| `sim/lib/mix/tasks/`, `sim/priv/qemu/` | Session startup, UI launcher, setup, scenario CLI and app install |
| `new/` | Application generator templates |
| `systems/` | EC100 and QEMU Nerves systems |

## Data flow

```text
UI / IEx → NervesGate command → domain GenServer → bounded worker
         → NervesGate.status → domain reads → Status.build

Subsystem observations → ProjectionServer → sanitized domain replacements
LiveView → subscription + snapshot → Projection reducer → UI
Domain conditions → Alarmist → LEDs / subscribers
```

`NervesGate.status/1` reads domains directly; it is not an atomic cross-domain
snapshot. Commands return their result without a status read. See the
[public API](action-api.md) for completion and error semantics.

## Ownership and supervision

| Owner | Responsibility |
| --- | --- |
| VintageNet | Interfaces, saved network settings, connectivity, DNS and routes |
| Tailscale | Identity, preferences, enrollment and VPN routes |
| Network | Admission, trials, USB auto-save, deadlines and rollback |
| Remote | One bounded daemon worker and sanitized operation metadata |
| Equipment | Neighbors, scoped labels and Network-owned scan observations |
| Indicators | LED/button policy, identification and recovery |
| Buses | One diagnostic worker, opt-in and bounded results |
| SSH | Public-key validation, persistence and authentication |
| Storage | SD-card commissioning, detection, mounting and explicit formatting |
| Apps | Trusted OTP application admission, lifecycle and version selection |
| ProjectionServer | Shared sanitized UI read model |
| LiveView | Drafts, presentation, subscriptions and command submission |

`firmware/config/firmware.exs` defines the shared device services. The application's
`rest_for_one` order is PubSub, routing setup, workflow PropertyTable, SSH, Network,
Remote, Equipment, Indicators, Buses, the app task supervisor, Storage, Apps,
ProjectionServer, SDKBackend and Endpoint. Dependencies supervise VintageNet, tailscaled and
Alarmist. Workstation UIs (`sim/config/`) start no device domains.

Firmware starts `nerves_gate` as `transient`: ordinary child failures recover under
supervision; abnormal application exit, including an exhausted restart limit,
terminates the BEAM and erlinit reboots the device. An orderly application stop
remains possible. Dependency application start modes are unchanged.

Workers are linked and bounded; owners stop and join them before restoration or
new work. Network replies after hardware completion; Remote acknowledges acceptance
and reports completion in status. A caller timeout means **unknown outcome**, not
cancellation or permission to replay. The facade sanitizes process-call failures;
programming exceptions remain visible.

Cross-domain commands enter through the facade. Scans and sharing hold Network's
admission guard. UI availability never replaces backend checks.

## Persistence and recovery

Network applies saved settings before accepting proposals; unreadable settings
fail closed. Trials and deadlines live in RAM. Proposals apply with `persist: false`;
confirmation saves each interface through VintageNet. Failed restoration retries
with new proposals blocked.

**Multi-interface persistence is not transactional.** Rollback cannot undo partial
disk writes; reboot uses whatever VintageNet saved. Tailscale owns its identity and
preferences, Equipment its labels and SSH its authorized keys. See
[saving and rollback](networking.md#saving-and-rollback).

Both firmware targets require writable ext4 data before starting data users.
Startup sets default-deny IPv4 forwarding before enabling forwarding; Tailscale
owns VPN rules. EC100 reset stops writers, unmounts data and invokes Nerves reset.
See [reset safety](indicators.md#recovery).

## UI projection

[`ProjectionServer`](../firmware/lib/nerves_gate/projection_server.ex) coalesces subsystem
observations for 20 ms, reads dirty domains and broadcasts changed sanitized inputs
as `{:replace, domain, snapshot}`. Remote changes also invalidate Network.
[`Projection`](../firmware/lib/nerves_gate/projection.ex) and [`Status`](../firmware/lib/nerves_gate/status.ex)
derive the same status on the device and clients.

Subscribing registers the LiveView and returns `{:ok, server_pid, projection}`.
Clients monitor that server, ignore messages from replaced instances and resubscribe
for a fresh snapshot after loss. Drafts remain separate. Private login URLs and
cookies never enter this stream.

The gateway backend is local on firmware and an explicit remote node on the
workstation; each simulator device page subscribes to its own node. Disconnected
clients show unavailable.

## Fault reporting

Domains publish fixed, sanitized conditions through SASL to Alarmist. Named domain
instances scope alarms by server name; unnamed instances publish none.
Restore/recovery failures are immediate errors. Availability faults become warnings
after two continuous seconds and clear on observed recovery. Unknown observations
stay unknown; rejected commands are not availability alarms.

Alarmist owns timing and subscriptions; Indicators derives LED policy. Alarms never
admit commands or trigger automatic remedies. See [LED policy](indicators.md#leds).

## Applications and SDK

`NervesGate.SDKBackend` translates domain state into SDK-owned structs and
delivers events to subscribing processes; it never exposes status maps or
administrative commands. `NervesGate.Buses` owns CAN/RS485 access for both
diagnostics and the SDK, so an application claim and a diagnostic cannot use the
same port. `NervesGate.Apps` installs, starts, upgrades and rolls back standard
`.ez` OTP archives from the SD card, persisting only each application's selection
under `/data/nerves_gate/apps.term`. See [applications](applications.md).

## Host-mode contract

Firmware is also the shared gateway-UI library. Its host config starts no device
services. Only simulator launchers configure `config :nerves_gate, services:` with
`NervesGateSim.HostInit` and `NervesGateWeb.Endpoint`, and explicitly start that
application. Native networking dependencies compile on the host for their
behaviours and configuration types but never start there. Host tools must not
start VintageNet, tailscaled or any device domain.

Simulator production paths use the public facade, gateway backend and projection
reducer, the shared endpoint/components, PubSub and distribution setup. Product
scenarios additionally inspect private domains to verify failure recovery; those
checks are not a public API for third-party apps. Independent package versions
remain supported, with explicit SDK requirements and shared-lock checks rather
than an artificial common version.

## QEMU simulator

There is one simulator: `sim/`, which runs real firmware in QEMU and requires it.
`mix dev` serves the simulator site and supervises a separate Simulator BEAM.
`Simulator` owns build, start, stop and reset; `Simulator.Device` owns each QEMU
process, disk, QMP socket and Ethernet relay. `QemuTests` admits lifecycle,
configuration, manual control and scenario runs: independent device runs can
coexist, and `devices: :all` reserves the whole bench. Private socket networks and
libslirp carry real traffic without workstation network changes.

The site, CLI and CI share the same [scenarios and runner](development.md#scenarios).
`.reach.exs` enforces API boundaries and pure status/policy code. See
[coverage and limits](development.md#coverage-and-limits).
