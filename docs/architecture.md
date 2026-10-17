# Backend architecture

Domains own commands, deadlines and persistence. A device-owned projection caches
sanitized inputs for the UI; it never coordinates commands. Workstation Phoenix
uses the same device backend over Erlang distribution and starts no device services.

## Data flow

```text
LiveView / IEx → NervesGate commands → domain GenServer → bounded worker
              → NervesGate.status  → domain reads → pure Status.build

Subsystem observations → ProjectionServer → domain replacement operations
LiveView → subscribe + initial Projection → pure reducer → UI (drafts separate)
Domain conditions → SASL alarm_handler → Alarmist → LEDs / subscribers
```

[`NervesGate`](../lib/nerves_gate.ex) is the public entry point. Commands return
results without bundling a status read. `status/1` reads domains directly,
bypassing the UI cache; those reads are **not an atomic cross-domain snapshot**.
See the [public API](action-api.md) for calling conventions and completion semantics.

## Ownership and supervision

| Owner | Responsibility |
| --- | --- |
| VintageNet | Applied/saved interfaces, hotplug, addresses, connectivity and route selection |
| Tailscale | Identity, preferences, daemon state, enrollment and VPN routes |
| Network | Admission, trial, USB auto-save, deadlines, serial LAN work and rollback |
| Remote | One bounded daemon worker; sanitized operation/error metadata |
| Equipment | Neighbor observations, scoped labels and monitoring the Network-owned scan |
| Indicators | LED/button policy, identification and one bounded recovery worker |
| Buses | One diagnostic worker, ephemeral opt-in and bounded results |
| SSH | Public-key validation, serialized durable changes and authentication |
| PropertyTable | Subsystem properties and ephemeral workflow observations |
| ProjectionServer | Cached sanitized inputs, coalesced reads and ordered UI operations |
| Alarmist | Fault timing, severity and subscriptions; not admission or recovery |
| LiveView | Drafts, presentation, subscriptions and command submission |

Configuration supplies the service list: EC100 and QEMU share one list, and the
workstation UI has its own. The device's `rest_for_one` order is PubSub, one-time
routing setup, workflow PropertyTable, SSH, Network, Remote, Equipment, Indicators,
Buses, ProjectionServer, then Endpoint. Dependencies supervise VintageNet,
`tailscaled_ex` and Alarmist themselves. Host UI instances start neither domain
processes nor a projection mirror. The UI backend is `:local` on devices, or a
remote node (nil while disconnected) on the workstation; there is no local fallback.

Workers are linked and bounded. Owners stop and join them before restoration or
new work. Network uses deferred `GenServer.reply/2` after hardware completion;
Remote acknowledges acceptance and exposes completion through status. Caller
timeout means **unknown outcome**, not cancellation or permission to replay.
Only the public facade translates call exits into sanitized client errors;
programming exceptions are not hidden.

Cross-domain commands enter through the facade. Equipment scans and route changes
hold Network's existing worker/admission guard while consulting the other domain.
UI availability cannot replace these backend checks.

## Persistence and recovery

Network loads and applies saved settings before accepting proposals. Unreadable
configuration fails closed; failed restoration retries with proposals blocked.
Trials and their independent deadlines live in RAM, not in the browser or alarms.
See [saving and rollback](networking.md#saving-and-rollback) for operator behavior.

Proposals use `persist: false`; confirmation explicitly saves each interface
through VintageNet. Identical configuration does not imply it was saved. The
adapter waits for bounded configuration/bridge settlement. Restoration may force
deconfigure/configure because a killed caller can leave a configuration property
updated before the interface received it.

**Multi-interface persistence is not transactional.** Runtime rollback cannot
undo partial disk writes; restart uses whatever VintageNet saved. Tailscale owns
its identity/preferences, and Equipment persists scoped labels. No command replay
or application-wide recovery journal is introduced.

Firmware application startup sets default-deny IPv4 forwarding before enabling
forwarding; Tailscale owns VPN allow/NAT rules.
EC100 factory reset stops data writers, normally unmounts data and uses Nerves'
reset operation. Both devices use the same Nerves initialization hook, which
requires their data partition mounted writable ext4 before data users start.
Code that needs `nerves_runtime` lives in `firmware/` and is compiled only into
firmware. See [reset safety](indicators.md#recovery).

## UI projection

[`ProjectionServer`](../lib/nerves_gate/projection_server.ex) subscribes to domain
observations, coalesces invalidations for 20 ms and re-reads dirty domains only.
It broadcasts only changed sanitized inputs as `{:replace, domain, snapshot}`.
Remote changes also invalidate Network because sharing admission depends on Remote.

[`Projection`](../lib/nerves_gate/projection.ex) stores inputs and applies those
replacements. Both server and clients derive the whole status with the same pure
[`Status`](../lib/nerves_gate/status.ex) code, preserving cross-domain rules.
Device metadata travels with the inputs. Private login URLs and distribution
cookies do not.

One serialized subscribe call registers the actual LiveView and returns
`{:ok, server_pid, projection}`. Clients monitor that PID, ignore old-instance
operations, show unavailable on loss and retry with a fresh snapshot. The server
monitors clients for cleanup. There is no polling, revision history or replay.
Form drafts remain separate from observed status; panels share parent assigns.

## Fault reporting

Domains report fixed, sanitized conditions through SASL to Alarmist. Reports are
asynchronous so an unavailable alarm handler cannot block recovery. Named domain
instances use `{NervesGate.Alarms, server_name, fault}`; unnamed instances do not
publish global alarms.

- `network_restore_failed`, `led_restore_failed` and `recovery_failed` are immediate
  errors. Recovery failure has no automatic retry or clear.
- Availability conditions become managed warnings after two continuous seconds,
  clearing immediately on factual recovery. These cover Internet loss, cellular
  backup/unavailability, Tailscale availability/offline/health, equipment discovery
  and enabled bus-port loss.
- Intentional disablement removes a requirement, not proof of repaired hardware.
  Unknown observations preserve the last report rather than asserting recovery.
- Rejected commands, empty inventories and Modbus timeouts are not availability
  alarms. Unrelated successful commands cannot clear faults.

```elixir
Alarmist.subscribe_all()
Alarmist.get_alarms()                 # excludes raw debug conditions
Alarmist.get_alarms(level: :debug)    # include raw inputs
Alarmist.info()
```

Managed warnings use `{NervesGate.Alarms.Warning, server_name, fault}`. Rules/timers
survive producer restarts. LEDs consume these severities rather than maintaining
another debounce/history layer. Alarms are last-known reports, never proof of
readiness or a trigger for automatic remedies. See [LED policy](indicators.md#leds).

## QEMU bench

`mix dev` starts Phoenix and an empty host-only `Simulator` BEAM under MuonTrap.
Its lifecycle GenServer owns asynchronous build/start/stop/reset work and progress.
No firmware is built and no device boots until Start is admitted. Stop powers off
and preserves disks; Reset explicitly erases them without restarting. A new Start
builds and bootstraps; Start after Stop resumes the preserved disks. Phoenix stays
available through device failures. Each `Simulator.Device` owns its
QEMU process, disk, QMP socket and `Simulator.Network` Ethernet relay. UI and
scenario workers are distribution clients, not hardware owners. `TestQemu` only
adds scenario assertions and cleanup. `dev/` is compiled only on the host.
The QEMU Nerves system names the provisioning NIC `usb0` and sets the full serial
as its hostname before Erlang starts. Both targets use the same application
sources, data-initialization hook and standard VintageNetDirect configuration;
there is no separate QEMU application boot module. Runtime configuration derives
the bench-specific loopback node name from the system hostname; the distribution
module consumes that configuration without knowing the target.

Every new or reset device starts from the configured factory artifact, boots real
VintageNetDirect on USB Ethernet, and receives current firmware over the normal
SSH/fwup subsystem. Firmware triggers the A/B reboot. Optional provisioning uses
public commands over SSH, never injected state files or fabricated USB trust.
All devices share one firmware build; serial numbers burned into their separate
disks determine runtime node identities.

QEMU/libslirp supplies DHCP, DNS and outbound connectivity. Each device has private
Unix sockets and a restricted management backend with its own loopback address
for native Erlang distribution, HTTP and SSH. The UI initiates distribution;
the simulator uses a session-owned EPMD. No workstation networking, namespaces,
resolver files or firewall rules are configured.

The network API is a partial map of `internet`, `cables` and `uplink` settings.
That same owner validates updates, switches actual forwarding and bounds packet
queues. QMP mirrors cable state into carrier; topology changes never change NIC
identities or firmware settings. Published settings come from the forwarding
owner, not a second simulated status store. Guest health is still device-owned.
An IPv4 admission gate prevents virtual-host loopback mapping and cross-segment
escapes; it implements no network protocols. Equipment has no IP server.

QEMU starts paused until streams and saved carrier states are installed. Wiring
and fault selections survive VM replacement; queued traffic and libslirp live
state do not. Device transport failure stops the device supervision tree while
the simulator lifecycle owner and UI remain available. Admission stays blocked
until explicit Reset; interrupted bootstrap cannot be resumed blindly. The runner
also monitors the simulator BEAM; loss requires a session restart. There is no
bypass or silent hardware restart. Raw packet data is excluded
from status/crash reports and notifications. Loopback services, like the local UI,
trust workstation users; this is not an OS sandbox.

`QemuTests` remains the single UI/CLI admission/controller process for lifecycle,
manual controls and scenarios. It keeps the UI backend disconnected until all
devices are ready and rejects lifecycle operations during scenario/manual ownership.
Manual controls and ordinary Elixir scenarios use the same drivers, bounded operations and restoration
callbacks. Scenarios declare data with `spec/0` and receive `%{device: primary,
devices: devices}` in `run/1`. The UI and manual controls stay attached to the
primary device; multi-device scenarios address explicit handles. The runner
publishes confirmed primary topology separately from injected faults and observed
gateway state. Cleanup resumes a paused VM first and restores the default
network map; failure blocks the bench until Reset. Initial network creation is a
Start operation, not a hot upgrade of an existing bench.

New protocol peers or fault types can be added to these real networks and drivers
as needed. There is no scenario DSL, plugin registry or second simulator framework.

## Validation

`.reach.exs` enforces public API boundaries and pure status/policy code. The shared
[QEMU scenarios](development.md#one-scenario-folder-one-runner) exercise the real
device backend, persistence and UI projection lifecycle. Physical hardware and
security qualification have [explicit limits](development.md#coverage-and-limits).
