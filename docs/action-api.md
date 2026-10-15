# Public API

[`NervesGate`](../lib/nerves_gate.ex) exposes named, documented, typed functions
for LiveView, IEx/SSH and other interfaces. Commands return results; queries return
status. No client object or dispatcher is needed.

## Read, act, read again

```elixir
:ok = NervesGate.subscribe()
status = NervesGate.status()

settings = %{
  "mode" => "ports",
  "eth0" => %{"role" => "internet", "address" => %{"ip_method" => "dhcp"}},
  "eth1" => nil
}

{:ok, settings} = NervesGate.network_validate(settings)
{:ok, id} = NervesGate.network_propose(settings)

# Check connectivity, then keep the trial or call network_cancel(id).
:ok = NervesGate.network_confirm(id)
status = NervesGate.status()
```

| Function | Success |
| --- | --- |
| `network_validate(settings)` | `{:ok, normalized_settings}`; pure, no device required |
| `network_propose(settings, opts)` | `{:ok, trial_id}` after temporary application |
| `network_confirm(trial_id, opts)` | `:ok` after saving interface settings |
| `network_cancel(trial_id, opts)` | `:ok` after restoration |
| `remote_connect(hostname, opts)` | `:ok` after accepting connection/enrollment |
| `remote_configure(hostname, opts)` | `:ok` after accepting a hostname change |
| `remote_disconnect(opts)` | `:ok` after accepting `down`; enrollment is kept |
| `remote_login_url(opts)` | `{:ok, url_or_nil}`; private query |
| `equipment_scan(opts)` | `:ok` after a bounded ARP scan |
| `equipment_label(id, label, opts)` | `:ok` after saving a scope-local label |
| `equipment_share(opts)` | `:ok` after equipment subnet advertisement readback |
| `equipment_unshare(opts)` | `:ok` after equipment subnet withdrawal readback |
| `identify(opts)` | `:ok` once five-second identification starts |
| `ssh_add_key(public_key)` | `:ok` after validating and saving one OpenSSH public key |
| `ssh_remove_key(fingerprint)` | `:ok` after saving removal; existing SSH sessions remain open |
| `bus_configure(port, params, opts)` | `:ok`; CAN configuration accepted or RS485 opt-in changed |
| `bus_capture(port, opts)` | `:ok`; receive-only capture accepted |
| `modbus_read(port, params, opts)` | `:ok`; one authorized RTU read accepted |
| `status(opts)` | Current status map, read directly from domains |
| `subscribe(opts)` | `:ok`; subscriptions belong to the caller |

`opts` is always an optional keyword list. Configuration uses validated string
keys; hostname and trial ID are direct strings. Failures return
`{:error, %{code: code, message: message}}`, never raw adapter errors.

Cellular configuration adds `"internet" => %{"mode" => "cellular", "apn" => "..."}`
without an Ethernet Internet role, or uses `"mode" => "backup"` with Ethernet.
Omitting it preserves Ethernet-only behavior. Validation checks shape, not driver
availability; proposals require a [qualified modem](networking.md#modem-qualification-is-still-required).

## Completion and safety

Editors should pass the saved configuration they started from:

```elixir
base = NervesGate.status().network.desired
# Build a candidate that preserves settings outside this editor's scope.
{:ok, id} = NervesGate.network_propose(candidate, expected: base)
```

The Network process compares `:expected` with its current saved configuration
before applying anything. A mismatch returns `stale_network`; reload settings
rather than replaying the old candidate. Omitting `:expected` retains explicit
whole-configuration replacement for console callers.

Console proposals require confirmation with the **exact current trial ID**. Only
trusted server code may supply `:access` to verify first setup through USB; never
derive it from request parameters or forwarded headers. Immediately-ready USB
setup waits for auto-save; otherwise it acknowledges a pending trial. See
[saving and rollback](networking.md#saving-and-rollback) for deadlines, readiness
and partial-persistence limits.

Remote and bus acceptance is **not completion**. Observe `remote_access.operation`
and `.error`, or `buses.operation`, `.error` and `.result`. Each domain admits one
operation at a time. Private enrollment URLs come only from `remote_login_url/1`;
never log them or put them in status, notifications or shared UI assigns.

Network uses deferred hardware-completion replies with a 15-second caller timeout;
sharing allows 70 seconds. On `outcome_unknown`, **read status before considering a
retry**. Caller timeout does not cancel admitted work. Commands are not replayed
automatically, including after reconnect or domain restart.

Use the facade's `equipment_scan`, `equipment_share` and `equipment_unshare` rather
than internal worker entry points: they retain Network's cross-domain admission
guard. Sharing accepts no caller-supplied route. Enable requires the confirmed
equipment link/address; disable needs the confirmed subnet and available daemon.
Other advertisements are preserved and block LAN changes. See
[sharing limits](networking.md#equipment-sharing).

UI `actions` and `capabilities` are presentation metadata, **not authorization**.
Future interfaces must establish access control before calling commands. There is
no public/web reboot or factory-reset command.

## Bus parameters

```elixir
NervesGate.bus_configure("can0", %{"enabled" => true, "bitrate" => 125000})
NervesGate.bus_capture("can0")

NervesGate.bus_configure("ttyS3", %{"enabled" => true})
NervesGate.modbus_read("ttyS3", %{
  "unit" => 1, "function" => 3, "address" => 0, "count" => 2,
  "authorized" => true
})
```

Only can0/can1 and ttyS3/ttyS4 are eligible. Numbers also accept decimal strings;
booleans accept `"true"`/`"false"`. Modbus authorization means the operator approved
that request and ensured there is no other master; it is not access control.

Results include `port`, `kind`, `completed_at` and bounded `data`: `frames` for CAN,
`hex`/`bytes` for serial, or `unit`/`function`/`address`/`count`/`registers` for Modbus.
See [bus operations and safety](buses.md) for enablement, limits and qualification.

## Status

`status/1` reads domains independently, **not an atomic cross-domain snapshot**.
[`Status`](../lib/nerves_gate/status.ex) derives the JSON-encodable v6 map:

- `version`, `system`: shape version and firmware/runtime information.
- `network`: saved settings, trial, observations, readiness, recovery and errors.
- `connections`: port roles, conflicts, per-uplink connectivity, selected Internet
  source, overall health and backup state.
- `remote_access`: sanitized daemon observations, routes, operation and error.
- `sharing`: equipment `subnet`, `enabled` (`true`, `false` or unknown `nil`) and
  `other_routes` untouched by the control.
- `equipment`: scoped neighbors, labels and scan status.
- `indicators`: availability, button state, LED patterns, identification and recovery.
- `buses`: support, ports, configuration/observations, operation, result and errors.
- `ssh`: availability, public-key fingerprints/types/comments and persistence errors.
- `capabilities`, `actions`: presentation-only availability, labels and reasons.

Unknown routes are `nil`, not assumed empty. Advertisements prove neither approval
nor reachability. Network and Remote commands remain independent except where the
facade explicitly holds Network's guard. There is no cross-domain revision lock.

## Subscriptions

`subscribe/1` binds the caller to workflow metadata and adapter observations.
Notifications are `%PropertyTable.Event{}` or subsystem tuples, **hints to re-read
status**, not complete snapshots. Subscribe before reading and again after
reconnect or domain replacement. Failed subscriptions need retry; caller death
removes subscriptions.

LiveViews instead subscribe to the device-owned projection stream, receiving an
initial snapshot and sanitized replacements. They clear availability on server
loss and resubscribe for a fresh snapshot. See [projection lifecycle](architecture.md#ui-projection).

## Domain APIs and explicit instances

Each domain documents its own commands and accepts a server reference:
[Network](../lib/nerves_gate/network.ex), [Remote](../lib/nerves_gate/remote.ex),
[Equipment](../lib/nerves_gate/equipment.ex), [Indicators](../lib/nerves_gate/indicators.ex)
and [Buses](../lib/nerves_gate/buses.ex). Direct calls use ordinary OTP exit behavior;
the public facade normalizes process-call failures for clients.

Facade options select instances directly:

```elixir
opts = [network: network_server, remote: remote_server]
:ok = NervesGate.subscribe(opts)
status = NervesGate.status(opts)
```

Other server options are `:equipment`, `:indicators` and `:buses`.
[SSH](../lib/nerves_gate/ssh.ex) is a single device-owned store, not an instance-selectable service. See the
[QEMU scenarios](../test/scenarios) for real-device API examples.
