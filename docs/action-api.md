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

Application-owned local addressing and subnet advertisement use the separate typed
`NervesGateSDK.Network` lease API; see the [subnet-router plugin](../plugins/tailnet_subrouter/README.md).
It requires explicit operator enablement (`%{"role" => "application", "address" => nil}`
on an independent port), preserves Internet/USB and blocks platform reconfiguration
until owned resources are released or safely recovered.

The names below are under `NervesGate`. Configuration uses validated string keys;
hostname/trial IDs are plain strings. Failures return
`{:error, %{code: code, message: message}}`, never raw library/driver errors.

| Function | Success |
| --- | --- |
| `Network.validate(settings)` | `{:ok, normalized_settings}`; pure, no device required |
| `Network.propose(settings, opts \\ [])` | `{:ok, trial_id}` after temporary application |
| `Network.confirm(trial_id)` | `:ok` after saving interface settings |
| `Network.cancel(trial_id)` | `:ok` after restoration |
| `Network.recover_local()` | `:ok` after explicit orphaned local claim cleanup; never advertises or disconnects management |
| `Cellular.refresh()` | `:ok`; read-only SIM/modem refresh accepted |
| `Cellular.unlock(pin, opts \\ [])` | `:ok`; one unlock and private SIM-bound PIN save accepted; `track: true` returns `{:ok, id}` |
| `Cellular.save_pin(pin)` | `:ok`; one PIN verification and private save accepted (ready, PIN-protected SIM only) |
| `Cellular.reconnect()` | `:ok`; explicit cellular reconnection accepted; may disconnect remote access |
| `Cellular.forget_pin()` | `:ok`; private PIN deletion accepted, SIM protection unchanged |
| `Cellular.change_pin(current, new)` | `:ok`; one SIM PIN change accepted |
| `Cellular.set_pin_lock(enabled, pin)` | `:ok`; one SIM protection change accepted |
| `Cellular.save_authentication(apn, username, password)` | `:ok`; private APN-bound PAP save accepted |
| `Cellular.forget_authentication()` | `:ok`; private PAP deletion accepted |
| `Remote.connect(hostname, opts \\ [])` | `:ok`; connection/enrollment accepted |
| `Remote.configure(hostname, opts \\ [])` | `:ok`; hostname change accepted |
| `Remote.disconnect()` | `:ok`; `down` accepted, enrollment kept |
| `Remote.login_url()` | `{:ok, url_or_nil}`; explicit private read |
| `Indicators.identify()` | `:ok` once five-second identification starts |
| `SSH.add_key(public_key)` | `:ok` after validating/saving one OpenSSH public key |
| `SSH.remove_key(fingerprint)` | `:ok` after saving removal; existing sessions stay open |
| `Buses.configure(port, params)` | `:ok`; CAN configuration or RS485 opt-in accepted |
| `Buses.capture(port)` | `:ok`; receive-only capture accepted |
| `Buses.modbus_read(port, params)` | `:ok`; one authorized RTU read accepted |
| `Storage.setup(action, card_id \\ nil, confirmation \\ nil)` | `:ok`; storage setup accepted |
| `Distribution.cookie()` | `{:ok, cookie}`; explicit private read |
| `System.info()` | Sanitized `%{firmware: ..., source_revision: ..., target: ..., node: ..., elixir: ..., otp: ...}` |
| `NervesGate.status()` | Current administrative map, read directly from domains |
| `NervesGate.subscribe()` | `:ok`; subscriptions belong to the caller |

Network accepts `:expected` and trusted `:access`; Remote connect accepts
`:expected` and transient `:auth_key`; configure accepts `:expected`.
`Cellular.unlock/2` accepts `track: true` to return a server-issued completion ID
without changing the default `:ok` contract. There are no
server-swapping options or alternate instance arguments.

`Remote.connect(hostname, auth_key: key)` uses an auth key instead of browser
sign-in. Only the bounded worker uses it; it is never persisted or published.
Do not log it or put it in configuration.

## Cellular

Network settings add `"internet" => %{"mode" => "cellular", "apn" => ""}` without
an Ethernet Internet role, or `"mode" => "backup"` with one. Empty APN requests
automatic offline carrier defaults, falling back to the network default when
ambiguous. Explicit UI carrier choices also save an optional public `"provider"`
ID, rechecked against the SIM by the driver; credentials never enter settings.
Shape validation is pure; enabling cellular or changing its APN
also requires a [detected modem](networking.md#cellular-modem).

SIM commands acknowledge **acceptance**, not completion. Observe
`status.cellular.operation` and `.result` (`operation` and `error`, nil on success).
For a tracked unlock, wait for the exact matching `.result.id`; another client's
operation or a readiness observation is not its completion. SIM commands and
private credential storage are available with the qualified modem even while LAN
is the selected Internet source. Only data reconnection and automatic PIN unlock
require cellular enabled.
Observation refreshes retain the last command result; `.error` describes the latest
observation/operation failure. PINs are 4–8 ASCII digits. Saving requires enabled
PIN protection and verifies the PIN with one `CPWD` command retaining its value:
**a wrong PIN consumes an attempt**. A ready, unprotected SIM needs no unlock PIN. One-attempt auto-unlock, SIM binding, storage and uncertainty
rules are in [SIM commissioning](networking.md#sim-commissioning-and-saved-pin).
Never log PIN arguments.

PAP commands store credentials separately from network settings. Observe cellular
operation/result for storage completion; acceptance proves neither carrier
authentication nor Internet. APN-matched credentials apply before the next fresh
packet-context activation. Existing sessions are not interrupted. Apply a different
APN through a normal network trial, or explicitly call `Cellular.reconnect()` to
use new credentials with the already-applied APN. Reconnect changes no saved
settings or SIM protection and is never triggered by credential storage. These operations
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
| Network trial, app lease and SSH keys | After the requested bounded effect/readback or persistence |
| Cellular, Remote, Buses and Storage | After admission; observe `operation`, `error` and applicable `result`/readiness |
| Identify | After starting the bounded identification period |

Remote completion is in `status.remote`, not a private URL. Bus completion is in
`status.buses`. Private `Remote.login_url/0` and `Distribution.cookie/0` results
belong only in the requesting view; never log, broadcast or put them in status.

Trial calls allow 15 seconds; application leases allow 70. Other calls are
bounded too. Missing owners return unavailable; a lost process-call reply returns
`outcome_unknown`. A caller timeout does not cancel admitted work. **Read state
before considering a retry**; never blindly replay writes or PIN attempts.
Exceptions/throws unrelated to the protected `GenServer.call` exit boundary are
not converted into successful or generic command results.

Use caller-owned SDK network leases for local addressing and advertisement, not
private Remote/worker helpers. Cellular uses the same Network worker; there is no
independent cellular process. Legacy Equipment label/scan/share commands and joined
network settings are removed. See [equipment sharing](networking.md#equipment-sharing).

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
Pure [`Status`](../firmware/lib/nerves_gate/status.ex) builds schema **v9**:

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
- `sharing`: application-lease `subnet`, `enabled` (`true`, `false` or unknown `nil`) and
  `other_routes` untouched by the control.
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
[Indicators](../firmware/lib/nerves_gate/indicators.ex),
[Buses](../firmware/lib/nerves_gate/buses.ex), [SSH](../firmware/lib/nerves_gate/ssh.ex)
and [Storage](../firmware/lib/nerves_gate/storage.ex). Fixed infrastructure and raw
cellular helpers are private implementation boundaries, not alternate client APIs.
See [scenarios](../lib/scenarios/cases) for bounded explicit domain RPCs against
owned devices.
