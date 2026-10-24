# Administrative API

Device commands belong to named domain modules. [`NervesGate`](../firmware/lib/nerves_gate.ex)
provides only `status/0`, caller-owned `subscribe/0` and a domain API index. The
administrative API is separate from the typed [application SDK](../sdk/README.md).
There is no client object, command dispatcher or configurable server routing.

## Read, act, read again

```elixir
alias NervesGate.Network

:ok = NervesGate.subscribe()
status = NervesGate.status()

settings = %{
  "mode" => "ports",
  "eth0" => %{"role" => "internet", "address" => %{"ip_method" => "dhcp"}},
  "eth1" => nil
}

{:ok, settings} = Network.validate(settings)
{:ok, id} = Network.propose(settings)

# Check connectivity, then keep the trial or call Network.cancel(id).
:ok = Network.confirm(id)
status = NervesGate.status()
```

The names below are under `NervesGate`. Configuration uses validated string keys;
hostname/trial IDs are plain strings. Failures return
`{:error, %{code: code, message: message}}`, never raw library/driver errors.

| Function | Success |
| --- | --- |
| `Network.validate(settings)` | `{:ok, normalized_settings}`; pure, no device required |
| `Network.propose(settings, opts \\ [])` | `{:ok, trial_id}` after temporary application |
| `Network.confirm(trial_id)` | `:ok` after saving interface settings |
| `Network.cancel(trial_id)` | `:ok` after restoration |
| `Cellular.refresh()` | `:ok`; read-only SIM/modem refresh accepted |
| `Cellular.unlock(pin)` | `:ok`; one unlock and private SIM-bound PIN save accepted |
| `Cellular.save_pin(pin)` | `:ok`; one PIN verification and private save accepted |
| `Cellular.forget_pin()` | `:ok`; private PIN deletion accepted, SIM protection unchanged |
| `Cellular.change_pin(current, new)` | `:ok`; one SIM PIN change accepted |
| `Cellular.set_pin_lock(enabled, pin)` | `:ok`; one SIM protection change accepted |
| `Cellular.save_authentication(apn, username, password)` | `:ok`; private APN-bound PAP save accepted |
| `Cellular.forget_authentication()` | `:ok`; private PAP deletion accepted |
| `Remote.connect(hostname, opts \\ [])` | `:ok`; connection/enrollment accepted |
| `Remote.configure(hostname, opts \\ [])` | `:ok`; hostname change accepted |
| `Remote.disconnect()` | `:ok`; `down` accepted, enrollment kept |
| `Remote.login_url()` | `{:ok, url_or_nil}`; explicit private read |
| `Equipment.scan()` | `:ok` after a bounded ARP scan |
| `Equipment.label(id, label)` | `:ok` after saving a scope-local label |
| `Equipment.share()` | `:ok` after equipment subnet advertisement readback |
| `Equipment.unshare()` | `:ok` after equipment subnet withdrawal readback |
| `Indicators.identify()` | `:ok` once five-second identification starts |
| `SSH.add_key(public_key)` | `:ok` after validating/saving one OpenSSH public key |
| `SSH.remove_key(fingerprint)` | `:ok` after saving removal; existing sessions stay open |
| `Buses.configure(port, params)` | `:ok`; CAN configuration or RS485 opt-in accepted |
| `Buses.capture(port)` | `:ok`; receive-only capture accepted |
| `Buses.modbus_read(port, params)` | `:ok`; one authorized RTU read accepted |
| `Storage.setup(action, card_id \\ nil, confirmation \\ nil)` | `:ok`; storage setup accepted |
| `Distribution.cookie()` | `{:ok, cookie}`; explicit private read |
| `System.info()` | Sanitized `%{firmware: ..., target: ..., node: ..., elixir: ..., otp: ...}` |
| `NervesGate.status()` | Current administrative map, read directly from domains |
| `NervesGate.subscribe()` | `:ok`; subscriptions belong to the caller |

Only `Network.propose/2`, `Remote.connect/2` and `Remote.configure/2` have command
options: Network accepts `:expected` and trusted `:access`; Remote connect accepts
`:expected` and transient `:auth_key`; configure accepts `:expected`. There are no
server-swapping options or alternate instance arguments.

`Remote.connect(hostname, auth_key: key)` uses an auth key instead of browser
sign-in. Only the bounded worker uses it; it is never persisted or published.
Do not log it or put it in configuration.

## Cellular

Network settings add `"internet" => %{"mode" => "cellular", "apn" => ""}` without
an Ethernet Internet role, or `"mode" => "backup"` with one. Empty APN requests the
network default. Shape validation is pure; enabling cellular or changing its APN
also requires a [detected modem](networking.md#cellular-modem).

SIM commands acknowledge **acceptance**, not completion. Observe
`status.cellular.operation` and `.error`. PINs are 4–8 ASCII digits. Saving the PIN
of a ready SIM reapplies its current protection setting once: **a wrong PIN
consumes an attempt**. One-attempt auto-unlock, SIM binding, storage and uncertainty
rules are in [SIM commissioning](networking.md#sim-commissioning-and-saved-pin).
Never log PIN arguments.

PAP commands store credentials separately from network settings. Observe cellular
operation/error for storage completion; acceptance proves neither carrier
authentication nor Internet. APN-matched credentials apply before the next fresh
packet-context activation. Existing sessions are not interrupted. These operations
share Network's single worker, but trial rollback does not undo private credential
writes. Status includes only `authentication` and `authentication_apn`, never
username/password. See [PAP](networking.md#pap-authentication).

## Completion and safety

Editors pass the saved configuration they started from:

```elixir
base = NervesGate.status().network.desired
# Build a candidate preserving settings outside this editor's scope.
{:ok, id} = NervesGate.Network.propose(candidate, expected: base)
```

Network checks `:expected` before effects. A mismatch returns `stale_network`:
reload rather than replaying. Without `:expected`, the candidate replaces the whole
configuration. Remote editors similarly use
`Remote.configure(name, expected: base)` or `Remote.connect(name, expected: base)`;
a changed hostname returns `stale_remote` before a daemon write.

Confirmation requires the **exact current trial ID**. Only trusted server code
may supply `:access` from actual socket observations for first USB setup. Never
derive it from form parameters/forwarded headers. Immediately-ready USB setup
waits for auto-save; otherwise it returns a pending trial. See
[saving and rollback](networking.md#saving-and-rollback).

| Command family | When the call succeeds |
| --- | --- |
| Network trial, scan, sharing, label and SSH keys | After the requested bounded effect/readback or persistence |
| Cellular, Remote, Buses and Storage | After admission; observe `operation`, `error` and applicable `result`/readiness |
| Identify | After starting the bounded identification period |

Remote completion is in `status.remote`, not a private URL. Bus completion is in
`status.buses`. Private `Remote.login_url/0` and `Distribution.cookie/0` results
belong only in the requesting view; never log, broadcast or put them in status.

Trial/scan calls allow 15 seconds; equipment sharing allows 70. Other calls are
bounded too. Missing owners return unavailable; a lost process-call reply returns
`outcome_unknown`. A caller timeout does not cancel admitted work. **Read state
before considering a retry**; never blindly replay writes or PIN attempts.
Exceptions/throws unrelated to the protected `GenServer.call` exit boundary are
not converted into successful or generic command results.

Use `Equipment.scan/share/unshare`, not private worker helpers: they hold Network's
cross-domain admission. Cellular uses the same worker; there is no independent
cellular process. Sharing accepts no caller-supplied route. See
[equipment sharing](networking.md#equipment-sharing).

Commands do not authenticate callers. `actions`/`capabilities` are presentation
metadata, **not authorization**. The gateway currently trusts reachable management
users, so restrict Ethernet/VPN/USB access. There is no public/web reboot or
factory-reset command.

## Bus parameters

```elixir
NervesGate.Buses.configure("can0", %{"enabled" => true, "bitrate" => 125_000})
NervesGate.Buses.capture("can0")

NervesGate.Buses.configure("ttyS3", %{"enabled" => true})
NervesGate.Buses.modbus_read("ttyS3", %{
  "unit" => 1, "function" => 3, "address" => 0, "count" => 2,
  "authorized" => true
})
```

Only can0/can1 and ttyS3/ttyS4 are eligible. Numbers also accept decimal strings;
booleans accept `"true"`/`"false"`. Modbus `authorized` means the operator approved
that request and ensured no other master; it is not access control.

Results include `port`, `kind`, `completed_at` and bounded `data`: CAN `frames`,
serial `hex`/`bytes`, or Modbus `unit`/`function`/`address`/`count`/`registers`.
See [bus operations](buses.md). Storage choice/erase confirmation is documented in
[application storage](applications.md#commissioning).

## Status

`NervesGate.status/0` reads domains independently: it is **not an atomic snapshot**.
Pure [`Status`](../firmware/lib/nerves_gate/status.ex) builds schema **v8**:

- `version`, `system`: schema version and sanitized firmware/runtime identity.
- `device`: availability/error; a disconnected projection client sets unavailable.
- `network`: saved settings, trial, observations, readiness, recovery and errors.
- `connections`: roles, conflicts, per-uplink connectivity, selected Internet
  source, overall health and backup state.
- `cellular`: modem/SIM observations, `pin_saved`, `auto_unlock`, operation/error,
  PAP `authentication`/`authentication_apn`. No PIN, credentials, SIM identity or
  binding hash. Auto-unlock is `ready`, `blocked`, `different_sim`,
  `identity_unknown`, `off` or `unknown`.
- `remote`: sanitized daemon observations, routes, operation and error.
- `sharing`: equipment `subnet`, `enabled` (`true`, `false` or unknown `nil`) and
  `other_routes` untouched by the control.
- `equipment`: scoped neighbors, labels and scan state.
- `indicators`: availability, button state, LED patterns, identify/recovery state.
- `buses`: ports, support, observations, operation, result and errors.
- `ssh`: public-key fingerprints/types/comments and persistence errors.
- `storage`: detected card, commissioning choice, readiness, operation and error.
- `capabilities`, `actions`: presentation-only availability, labels and safe reasons.
  Action names are domain-qualified, including `buses.configure`, `buses.capture`,
  `buses.modbus_read` and `indicators.identify`.

Unknown routes are `nil`, not empty. Advertisements prove neither route approval
nor reachability. There is no cross-domain revision lock, and the SDK does not
return this administrative map.

## Subscriptions and implementations

`NervesGate.subscribe/0` subscribes the actual caller to workflow and infrastructure
observation hints. `%PropertyTable.Event{}`/subsystem tuples mean **re-read status**,
not complete snapshots. Subscribe before reading and afresh after reconnect or an
owner restart. Caller death removes subscriptions.

LiveViews use the device-owned projection stream instead, with explicit local or
remote read-only sources. Gateway commands remain local; see
[UI projection](architecture.md#ui-projection).

Public owners document their own interfaces: [Network](../firmware/lib/nerves_gate/network.ex),
[Cellular](../firmware/lib/nerves_gate/cellular.ex), [Remote](../firmware/lib/nerves_gate/remote.ex),
[Equipment](../firmware/lib/nerves_gate/equipment.ex), [Indicators](../firmware/lib/nerves_gate/indicators.ex),
[Buses](../firmware/lib/nerves_gate/buses.ex), [SSH](../firmware/lib/nerves_gate/ssh.ex)
and [Storage](../firmware/lib/nerves_gate/storage.ex). Fixed infrastructure and raw
cellular helpers are private implementation boundaries, not alternate client APIs.
See [scenarios](../lib/scenarios/cases) for bounded explicit domain RPCs against
owned devices.
