# Backend architecture

Ordinary OTP owns commands and bounded I/O. Existing subsystem observations supply
reads. Alarmist reports persistent faults. There is no agent framework, central
state server, event store, command bus or application persistence journal.

## Start here

- [`NervesGate`](../lib/nerves_gate.ex): named public commands, status and subscriptions.
- [`Status`](../lib/nerves_gate/status.ex): pure, on-demand status projection.
- [`Network`](../lib/nerves_gate/network.ex): one GenServer for trials, USB auto-save,
  the rollback deadline and one bounded worker.
- [`Remote`](../lib/nerves_gate/remote.ex): one GenServer for Tailscale operations.
- [`Alarms`](../lib/nerves_gate/alarms.ex): asynchronous fault reporting, no process.

## Command/query separation, without a framework

Commands return `:ok`, `{:ok, value}` or a sanitized error. Read `NervesGate.status/1`
separately. It reads domains independently, not as an atomic cross-domain snapshot.
There is no stored read model or event replay. Exact trial IDs and serialized
operations protect mutations; UI action availability is only presentation metadata.

```text
LiveView / IEx → NervesGate named commands → domain GenServer → bounded worker
             → NervesGate.status         → domain reads → pure Status projection

Subsystem properties + workflow metadata → subscription hints → fresh status read
Domain conditions → SASL alarm_handler → Alarmist debounce/severity → LED policy/subscribers
```

| Owner | Responsibility |
| --- | --- |
| VintageNet | Saved/applied Ethernet settings, hotplug, addresses, routes and observations |
| Tailscale | Identity, preferences, daemon state, routes and enrollment |
| Network | Command admission/replies, RAM trial, USB auto-save, deadline, serial LAN work and rollback |
| Remote | One bounded daemon worker and sanitized operation/error metadata |
| Equipment | Bounded neighbor observations, scoped labels and monitoring the Network-owned active scan |
| Indicators | Three status LEDs, bounded identification and fixed release-only button gestures |
| Buses | One bounded diagnostic worker and ephemeral opt-in/results |
| PropertyTable | Subsystem properties and ephemeral workflow/host-simulation observations |
| Alarmist | Fault timing/severity and subscriptions; never command admission or recovery ownership |
| LiveView | Drafts, presentation, subscriptions and command submission |

## Supervision and work ownership

Application `rest_for_one` order is Phoenix PubSub, workflow PropertyTable, host
simulators (host only), Network, Remote, Equipment, Indicators, Buses, then Endpoint.
Dependencies supervise VintageNet, Tailscale and Alarmist themselves. There is no
application Registry or nested network supervisor.

Network reloads and applies saved settings before accepting trials. Failed
restoration blocks proposals and retries; unreadable saved configuration fails
closed. Workers are linked, bounded and killed/joined before restoration or new work.

Network uses ordinary `GenServer.call/3` with deferred `GenServer.reply/2` after
hardware completion (15-second caller timeout; sharing allows 70 seconds). A caller
timeout is an unknown outcome, not cancellation or permission to replay. OTP drops
late replies. Unexpected worker exceptions are logged and reach the owner via task
`:DOWN`. Only the public API translates call exits into unavailable/unknown-outcome
results; programming exceptions are not hidden. See [action-api.md](action-api.md).

## Network trials and persistence

Manual trials require confirmation within **60 seconds**. First setup through
**server-verified USB** may auto-save within **15 seconds**. The same GenServer
checks live readiness after applying settings and on observations/polling:

- Busy worker: never overlap operations.
- Expired trial: stop the worker and restore saved settings.
- Manual trial: wait for explicit confirmation.
- Automatic trial: save when ready, restore on conflicts, otherwise wait.

There are no decision messages, agent state, plugins or directives. The independent
trial timer and worker watchdog do not depend on the browser, Alarmist or successful
notification delivery. USB is never part of a LAN operation.

Proposals use `persist: false`. Confirmation explicitly saves each LAN interface
through VintageNet's persistence API; an identical-config call does not suffice.
VintageNet's asynchronous work still needs the adapter's bounded configuration and
bridge-membership settlement barrier. Restoration can force deconfigure/configure:
a killed caller may have updated the configuration property before the interface
received it, making an ordinary identical-config call a no-op.

**Saving interfaces is not a transaction.** Failure or power loss can leave partially
saved settings. Rollback restores the prior applied configuration, not an atomic
disk snapshot. Restart uses whatever VintageNet saved. No durable trial journal,
commit marker or cross-interface recovery layer exists. Only mode and port labels
supplement the subsystem settings; host persistence is memory-only. Keep USB/serial
recovery available. See [networking.md](networking.md).

## Fault reporting

Alarmist 0.4.x handles the standard SASL alarm events. Named domain instances report:

| Alarm ID | Set | Clear |
| --- | --- | --- |
| `{NervesGate.Alarms, NervesGate.Network, :network_restore_failed}` | Restoring saved LAN settings fails | Restoration succeeds, including successful startup |
| `{NervesGate.Alarms, NervesGate.Indicators, :led_restore_failed}` | A status LED cannot be controlled | Reconciliation applies current patterns successfully |
| `{NervesGate.Alarms, NervesGate.Indicators, :recovery_failed}` | Physical recovery fails or its outcome is unknown | No automatic retry/clear |
| `{NervesGate.Alarms, NervesGate.Equipment, :equipment_discovery_unavailable}` | Passive neighbor discovery fails, crashes or times out after obtaining a confirmed scope | A passive observation succeeds (including empty results), or equipment configuration is removed |
| `{NervesGate.Alarms, NervesGate.Remote, :remote_unavailable}` | Daemon becomes unavailable after a connect request or an active authentication/connection observation | Daemon is available again |
| `{NervesGate.Alarms, NervesGate.Network, :internet_unavailable}` | Configured uplink reports `:lan` or `:disconnected` | Uplink reports `:internet`, or its configured requirement is removed |
| `{NervesGate.Alarms, NervesGate.Remote, :remote_offline}` | Authenticated, enabled Tailscale reports offline | Reports online, awaits enrollment/approval, or is deliberately stopped |
| `{NervesGate.Alarms, NervesGate.Remote, :remote_health}` | Enabled Tailscale reports health warnings | Health warnings clear, or remote access is deliberately stopped |
| `{NervesGate.Alarms, NervesGate.Buses, :bus_port_unavailable}` | A known enabled CAN/RS485 port is missing | Missing enabled ports return, or their enablement is removed |

```elixir
Alarmist.subscribe_all()
Alarmist.get_alarms()
Alarmist.info()
```

Restore/recovery faults have immediate `:error` severity. Other IDs above are raw
`:debug` conditions. `{NervesGate.Alarms.Warning, server_name, fault}` is their
managed `:warning` alarm: `debounce(condition, 2_000)`. It clears immediately when
the condition clears. Each domain registers once on startup, retaining existing
rules/timers across producer restarts. `get_alarms()` excludes raw debug inputs;
use `get_alarms(level: :debug)` for diagnostics. LEDs use Alarmist severity and
managed connectivity warnings, not a second debounce/history implementation.

VintageNet per-interface connection observations select the configured Internet port
or shared bridge, not the global best connection or USB. Tailscale state and health
remain separate facts. Running does not prove Internet or control-server access.
Unknown observations preserve faults and never qualify USER1 for solid illumination.

Raw reports have fixed descriptions, stable server-name identities, and no settings or
private URLs. Unnamed test instances do not publish global alarms. Reporting is
fire-and-forget and cannot block recovery when the alarm handler is unavailable or
stalled. Each domain reports through its existing observation/completion paths;
there is no new polling process or alarm coordinator. Command rejection, label or
scan errors, an empty inventory, and a Modbus timeout are not availability alarms.
A successful unrelated command cannot clear a fault.

Remote remembers whether connection was requested or observed active, not a replayable
command. Observed stopped/needs-login states withdraw that expectation. Bus enablement
comes from observed CAN state and explicit serial opt-in; missing ports cannot silently
erase it. Serial opt-in still resets on restart. Unknown network scope, unknown remote
intent at startup, or unknown CAN enablement preserve the last report rather than
assert recovery. Removing a configuration/opt-in clears the corresponding requirement;
it does not claim that the hardware was repaired.

Alarms are last-known reports, not proof of readiness. LED startup reconciles the
current normal patterns; it no longer restores an old raw brightness snapshot.
Neither alarms nor settings form a durable recovery journal. Alarmist's unknown
state must not be interpreted as healthy for command admission. There are no automatic
remedies, DHCP restarts, VPN reconnects,
DNS resets, failover or enrollment.

## Other domains stay simple

- **Remote:** one asynchronous operation at a time; acceptance is not completion.
  Restart observes the daemon and never replays mutations. Disconnect uses `down`,
  not logout. Enrollment URLs are private reads, never status or property data.
- **Sharing:** holds the existing LAN worker while Remote adds/removes the confirmed
  equipment IPv4 subnet and verifies readback. No site IDs or address translation.
  Other advertisements are preserved; any advertised or uncertain routes block LAN
  changes. A read-only Controller barrier handles earlier accepted daemon work.
  A small firmware boot script sets default-deny IPv4 forwarding before OTP starts;
  Tailscale owns its allow/NAT rules. No routing manager or lifecycle coordinator.
  Readback does not prove tailnet approval, reachability or traffic termination.
- **Equipment:** passive rtnetlink observations; an explicit ARP scan is owned by
  Network and bounded to five seconds and at most /24. Inventory/labels are capped
  at 256 entries. Scope changes clear observations, not labels. USB is ineligible.
- **Indicators:** pure LED/button policy in the existing process, cached outputs,
  Network/Remote/Alarmist subscriptions plus five-second reconciliation, and monotonic blink/
  gesture timing. Identify lasts five seconds and resumes current patterns. One
  bounded worker calls a small recovery adapter; no recovery GenServer or retries.
  Graceful shutdown turns owned LEDs off; abrupt VM loss can leave them latched.
  EC100 reset stops writers, normally unmounts data, then uses standard Nerves reset.
  A Nerves initialization hook checks rw ext4 before data services start; no extra
  long-running process. See [indicators](indicators.md).
- **Buses:** one 6.5-second bounded worker, listen-only CAN, passive serial capture
  or explicitly authorized Modbus functions 3/4. No automatic traffic, writes,
  retries, replay or persisted intent. See [buses.md](buses.md).

## Notifications, UI and validation

LiveViews subscribe to subsystem properties and workflow metadata, coalesce bursts
for 20 ms and reread status. Subscribe before reading and after reconnecting.
Unavailable subscriptions retry; polling repairs missed hints. Caller death removes
subscriptions. There is no duplicate PubSub lifecycle bus. Editors retain drafts;
read-only panels share parent assigns. See [ui.md](ui.md).

`.reach.exs` enforces public API boundaries and pure policy/status code. Tests cover
USB access verification, stale IDs, conflicts, worker death/timeouts, deadline and
restoration behavior, partial persistence, caller timeout, subscription cleanup and
alarm lifecycle. Isolated integration scripts exercise Linux LAN/USB peers and a
private userspace Tailscale daemon. Builds never flash a device.

Physical cable, LED, CAN, USB and power-loss qualification remains necessary. The
independently reproduced OTP 29/MuonTrap `:epipe` command-runner race remains unfixed;
see [networking.md](networking.md). HTTP remains unauthenticated for trusted networks,
with CSRF/same-origin safeguards unchanged. Host simulation never touches workstation
networking, VPN or hardware.
