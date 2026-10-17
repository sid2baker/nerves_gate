# Architecture

Device domains own commands, admission, deadlines and persistence. The gateway UI
reads a device-owned projection and submits commands through [`NervesGate`](../lib/nerves_gate.ex).
EC100 and QEMU run the same application. Workstation UIs connect over Erlang distribution.

## Source map

| Path | Responsibility |
| --- | --- |
| `lib/nerves_gate.ex` | Public commands, status and subscriptions |
| `lib/nerves_gate/` | Device domains, adapters and projection |
| `lib/nerves_gate_web/` | Gateway endpoint, LiveViews and components |
| `dev/simulator.ex`, `dev/simulator/` | Simulator lifecycle and owned virtual hardware |
| `dev/simulator_web/` | Simulator endpoint, overview, device tests and CLI API |
| `dev/mix/tasks/`, `dev/*.exs` | Setup, session startup, UI launcher and scenario CLI |
| `test/support/runner.ex` | Shared runner and device reservations |
| `test/scenarios/` | Real-device integration scenarios |
| `config/` | Common, host and firmware profiles |

## Data flow

```text
UI / IEx → NervesGate command → domain GenServer → bounded worker
         → NervesGate.status → domain reads → Status.build

Subsystem observations → ProjectionServer → sanitized domain replacements
LiveView → subscription + snapshot → Projection reducer → UI
Domain conditions → Alarmist → LEDs / subscribers
```

`NervesGate.status/1` reads domains directly; it is not an atomic cross-domain
snapshot. Commands return their result without bundling a status read. See the
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
| ProjectionServer | Shared sanitized UI read model |
| LiveView | Drafts, presentation, subscriptions and command submission |

`config/firmware.exs` defines the shared device service list. The application's
`rest_for_one` order is PubSub, routing setup, workflow PropertyTable, SSH, Network,
Remote, Equipment, Indicators, Buses, ProjectionServer and Endpoint. Dependencies
supervise VintageNet, tailscaled and Alarmist. `config/host.exs` configures workstation
services; workstation UIs start no device domains.

Workers are linked and bounded. Owners stop and join them before restoration or
new work. Network replies after hardware completion; Remote acknowledges acceptance
and exposes completion in status. Caller timeout means **unknown outcome**, not
cancellation or permission to replay. The public facade sanitizes process-call
failures; programming exceptions remain visible.

Cross-domain commands enter through the facade. Scans and sharing hold Network's
admission guard. UI availability never replaces backend checks.

## Persistence and recovery

Network applies saved settings before accepting proposals. Unreadable settings
fail closed. Trials and deadlines live in RAM. Proposals apply with `persist: false`;
confirmation saves each interface through VintageNet. Failed restoration retries
with new proposals blocked.

**Multi-interface persistence is not transactional.** Runtime rollback cannot undo
partial disk writes; reboot uses whatever VintageNet saved. Tailscale owns its
identity/preferences, Equipment its labels and SSH its authorized keys. See
[saving and rollback](networking.md#saving-and-rollback).

Both firmware targets require writable ext4 data before starting data users.
Application startup sets default-deny IPv4 forwarding before enabling forwarding;
Tailscale owns VPN rules. EC100 reset stops writers, unmounts data and invokes Nerves
reset. See [reset safety](indicators.md#recovery).

## UI projection

[`ProjectionServer`](../lib/nerves_gate/projection_server.ex) coalesces subsystem
observations for 20 ms, reads dirty domains and broadcasts changed sanitized inputs
as `{:replace, domain, snapshot}`. Remote changes also invalidate Network.
[`Projection`](../lib/nerves_gate/projection.ex) and [`Status`](../lib/nerves_gate/status.ex)
derive the same status on the device and clients.

Subscribe registers the LiveView and returns `{:ok, server_pid, projection}`.
Clients monitor that server, ignore messages from replaced instances and resubscribe
with a fresh snapshot after loss. Drafts remain separate. Private login URLs and
cookies never enter this stream.

The gateway backend is local on firmware and an explicit remote node on the
workstation. Disconnected clients show unavailable. Each simulator device page
subscribes to its own node.

## Fault reporting

Domains publish fixed, sanitized conditions through SASL to Alarmist. Named domain
instances scope alarms by server name; unnamed instances publish no global alarms.
Restore/recovery failures are immediate errors. Availability faults become warnings
after two continuous seconds and clear on observed recovery. Unknown observations
remain unknown; rejected commands are not availability alarms.

Alarmist owns timing and subscriptions; Indicators derives LED policy. Alarms do not
admit commands or trigger automatic remedies. See [LED policy](indicators.md#leds).

## QEMU bench

- `mix dev` serves the simulator site and supervises a separate Simulator BEAM.
- `Simulator` owns build/start/stop/reset work. `Simulator.Device` owns each QEMU
  process, disk, QMP socket and Ethernet relay.
- `QemuTests` admits lifecycle, configuration, manual controls and scenario runs.
  Independent device runs can coexist; `devices: :all` reserves the whole bench.
- `/` edits persisted device configuration while stopped. Adding/removing devices
  requires empty disks because sorted IDs determine serials and addresses.
- `/devices/:id` shows that device's projection, topology, faults and test results.
- `mix dev.ui` serves the gateway UI with reload against one simulated or real node.

Start builds shared firmware and bootstraps new disks through USB SSH/fwup. Stop
preserves disks; Reset erases them. Cleanup resumes paused VMs and restores baseline
wiring. Uncertain control blocks affected devices until Reset; simulator loss
requires a session restart.

Private socket networks and libslirp carry real traffic without workstation network
changes. Loopback access trusts local users. The site, CLI and CI use the same
[scenarios and runner](development.md#one-scenario-folder-one-runner).

## Validation

`.reach.exs` enforces API boundaries and pure status/policy code. Shared QEMU
scenarios exercise device behavior and persistence. See
[coverage and limits](development.md#coverage-and-limits) for hardware qualification.
