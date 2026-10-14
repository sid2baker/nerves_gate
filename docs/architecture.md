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
| PropertyTable | Subsystem properties and ephemeral workflow observations |
| ProjectionServer | Cached sanitized inputs, coalesced reads and ordered UI operations |
| Alarmist | Fault timing, severity and subscriptions; not admission or recovery |
| LiveView | Drafts, presentation, subscriptions and command submission |

The device's `rest_for_one` order is PubSub, workflow PropertyTable, Network,
Remote, Equipment, Indicators, Buses, ProjectionServer, then Endpoint. Dependencies
supervise VintageNet, Tailscale and Alarmist themselves. Host UI instances start
neither domain processes nor a projection mirror.

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
reset operation. A Nerves initialization hook checks writable ext4 before data
users start. See [reset safety](indicators.md#recovery).

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

## Validation

`.reach.exs` enforces public API boundaries and pure status/policy code. The shared
[QEMU scenarios](development.md#one-scenario-folder-one-runner) exercise the real
device backend, persistence and UI projection lifecycle. Physical hardware and
security qualification have [explicit limits](development.md#coverage-and-limits).
