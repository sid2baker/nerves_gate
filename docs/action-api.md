# Public API

[`NervesGate`](../firmware/lib/nerves_gate.ex) exposes named, documented, typed functions
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
keys; hostname and trial ID are plain strings. Failures return
`{:error, %{code: code, message: message}}`, never raw adapter errors.

`remote_connect(hostname, auth_key: key)` enrolls with an auth key instead of a
browser sign-in link. Only the bounded remote worker uses the key; it is never
persisted or included in status or events. Do not log it or put it in configuration.

Cellular configuration adds `"internet" => %{"mode" => "cellular", "apn" => "..."}`
without an Ethernet Internet role, or `"mode" => "backup"` with one. Without it,
the gateway is Ethernet-only. Validation checks shape, not hardware; proposals
require a [configured modem](networking.md#cellular-modems).

## Completion and safety

Editors pass the saved configuration they started from:

```elixir
base = NervesGate.status().network.desired
# Build a candidate that preserves settings outside this editor's scope.
{:ok, id} = NervesGate.network_propose(candidate, expected: base)
```

Network compares `:expected` with its saved configuration before applying anything.
A mismatch returns `stale_network`: reload rather than replaying the old candidate.
Without `:expected`, the candidate replaces the whole configuration.

Tailscale editors likewise pass the hostname they started from:
`remote_configure(name, expected: base)` or `remote_connect(name, expected: base)`.
Remote returns `stale_remote` if the hostname has changed, before any daemon write.

Confirmation requires the **exact current trial ID**. Only trusted server code may
pass `:access` to verify first setup through USB; never derive it from request
parameters or forwarded headers. Immediately-ready USB setup waits for auto-save;
otherwise it returns a pending trial. See [saving and rollback](networking.md#saving-and-rollback).

Remote and bus acceptance is **not completion**. Observe `remote_access.operation`
and `.error`, or `buses.operation`, `.error` and `.result`. Each domain runs one
operation at a time. Private enrollment URLs come only from `remote_login_url/1`;
never log them or put them in status, notifications or shared UI assigns.

Network calls time out after 15 seconds; sharing allows 70. On `outcome_unknown`,
**read status before considering a retry**. A caller timeout does not cancel
admitted work, and commands are never replayed automatically.

Use the facade's `equipment_scan`, `equipment_share` and `equipment_unshare`, not
internal worker entry points: they hold Network's cross-domain admission guard.
Sharing takes no caller-supplied route. See [equipment sharing](networking.md#equipment-sharing).

Commands perform no access control. UI `actions` and `capabilities` are
presentation metadata, **not authorization**; every interface must control access
before calling commands. There is no public or web reboot or factory-reset command.

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
booleans accept `"true"`/`"false"`. Modbus `authorized` means the operator approved
that request and ensured there is no other master; it is not access control.

Results include `port`, `kind`, `completed_at` and bounded `data`: `frames` for CAN,
`hex`/`bytes` for serial, or `unit`/`function`/`address`/`count`/`registers` for
Modbus. See [bus operations](buses.md).

## Status

`status/1` reads domains independently; it is **not an atomic snapshot**.
[`Status`](../firmware/lib/nerves_gate/status.ex) builds the JSON-encodable v6 map:

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

Unknown routes are `nil`, not empty. Advertisements prove neither approval nor
reachability. There is no cross-domain revision lock.

## Subscriptions

`subscribe/1` binds the caller to workflow metadata and adapter observations.
Notifications (`%PropertyTable.Event{}` or subsystem tuples) are **hints to re-read
status**, not snapshots. Subscribe before reading and again after reconnecting or a
domain restart. Caller death removes subscriptions.

LiveViews use the device-owned projection stream instead; see
[UI projection](architecture.md#ui-projection).

## Domain APIs and explicit instances

Each domain documents its own commands and accepts a server reference:
[Network](../firmware/lib/nerves_gate/network.ex), [Remote](../firmware/lib/nerves_gate/remote.ex),
[Equipment](../firmware/lib/nerves_gate/equipment.ex), [Indicators](../firmware/lib/nerves_gate/indicators.ex)
and [Buses](../firmware/lib/nerves_gate/buses.ex). Direct calls use ordinary OTP exit
behavior; the facade normalizes process-call failures.

Facade options select instances:

```elixir
opts = [network: network_server, remote: remote_server]
:ok = NervesGate.subscribe(opts)
status = NervesGate.status(opts)
```

Other options are `:equipment`, `:indicators` and `:buses`.
[SSH](../firmware/lib/nerves_gate/ssh.ex) is a single device-owned store. See the
[QEMU scenarios](../firmware/test/scenarios) for examples against real devices.
