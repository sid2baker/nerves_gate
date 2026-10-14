# NervesGate public API

Start with [`lib/nerves_gate.ex`](../lib/nerves_gate.ex). It contains the named,
documented, typed functions used by LiveView and IEx/SSH. There is no public
string dispatcher, client struct, facade process or cached status server.
Commands and queries stay separate without a CQRS framework or stored read model.

## Domain APIs

Each domain documents its commands, queries and completion semantics in its module:

- [`Network`](../lib/nerves_gate/network.ex): validate, propose, confirm, cancel and status.
- [`Equipment`](../lib/nerves_gate/equipment.ex): labels and inventory status.
- [`Remote`](../lib/nerves_gate/remote.ex): connect, configure, disconnect, login URL and status.
- [`Buses`](../lib/nerves_gate/buses.ex): configure, capture, Modbus read and status.
- [`Indicators`](../lib/nerves_gate/indicators.ex): identify, fixed physical gestures and status.

Each has `observe/1` and accepts an optional server reference. Direct domain calls
use ordinary OTP exit behavior; `NervesGate` handles process-call failures and
normalizes errors for clients. Use `NervesGate.equipment_scan/1`, `equipment_share/1`
and `equipment_unshare/1` so cross-domain operations retain Network's safety guard.
The worker entry points they call are internal and marked `@doc false`.

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

# Inspect connectivity before keeping the trial. Or call network_cancel(id).
:ok = NervesGate.network_confirm(id)
status = NervesGate.status()
```

To select cellular-only, omit the Ethernet Internet role and add
`"internet" => %{"mode" => "cellular", "apn" => "operator.apn"}`. For Ethernet-preferred
backup keep that role and use `"mode" => "backup"` inside the Internet object.
Omitting `internet` preserves Ethernet-only behaviour. Shared Ethernet supports backup,
not cellular-only. Proposals require a qualified firmware modem profile; validation is
pure and does not claim driver availability. Host support is explicitly simulated.

Commands return their result, not a status envelope:

| Function | Success |
| --- | --- |
| `network_validate(settings)` | `{:ok, normalized_settings}`; pure, no running gateway required |
| `network_propose(settings, opts)` | `{:ok, trial_id}` after temporary application |
| `network_confirm(trial_id, opts)` | `:ok` after VintageNet saves the interface settings |
| `network_cancel(trial_id, opts)` | `:ok` after restoration |
| `remote_connect(hostname, opts)` | `:ok` after accepting connection/enrollment |
| `remote_configure(hostname, opts)` | `:ok` after accepting a hostname change |
| `remote_disconnect(opts)` | `:ok` after accepting `down`; enrollment is kept |
| `remote_login_url(opts)` | `{:ok, url_or_nil}`; private query |
| `equipment_scan(opts)` | `:ok` after a bounded ARP scan |
| `equipment_label(id, label, opts)` | `:ok` after saving a scope-local label |
| `equipment_share(opts)` | `:ok` after confirmed equipment IPv4 subnet advertisement readback |
| `equipment_unshare(opts)` | `:ok` after that equipment subnet's withdrawal readback |
| `identify(opts)` | `:ok` once five-second identification starts; afterward current LED patterns resume |
| `bus_configure(port, params, opts)` | `:ok`; accepted live CAN configuration, or RS485 opt-in changed |
| `bus_capture(port, opts)` | `:ok`; receive-only capture accepted |
| `modbus_read(port, params, opts)` | `:ok`; one authorized RTU read accepted |
| `status(opts)` | A current status map |
| `subscribe(opts)` | `:ok`; subscriptions belong to the caller |

All `opts` arguments are optional keyword lists. Settings retain their validated
string-keyed configuration format; hostname and trial ID are direct string
arguments, not JSON command envelopes. Failures return
`{:error, %{code: code, message: message}}`; raw adapter errors are not public data.

## Timing and safety

Console proposals require confirmation. Only trusted server code may supply the
`:access` option to verify first setup through USB. Never derive it from request
parameters or forwarded headers. All subsequent changes require confirmation,
including those through USB.

Immediately-ready first USB setup waits for auto-save before returning.
If application is still settling, Network acknowledges the pending trial and
later saves when ready. Conflicts and persistence failures are not successful
auto-saves. Network independently enforces the 15-second USB bound and the
60-second manual confirmation window. Confirmation saves interfaces individually;
interrupted or failed persistence can leave a partial save. There is no durable
trial journal or multi-interface transaction. See [networking](networking.md).

Remote acceptance is **not completion**. Observe `status.remote_access.operation`
and `.error`. One bounded asynchronous operation runs at a time. Enrollment URLs
are delivered only by `remote_login_url/1`, never placed in status, server state
or subscribed properties. Do not log or broadcast them.

Network commands use one standard OTP call with a 15-second timeout and deferred
hardware-completion replies. No agent or alarm handler participates in admission.
On `outcome_unknown`, **read status before deciding whether to retry**. Caller
timeout does not cancel an admitted command. Network recovery remains independent
of the caller; a daemon mutation may complete after its caller dies. Uncertain
commands are not automatically replayed. There is no exactly-once acknowledgment
or durable command queue.

Identify temporarily overrides all three status channels. Overlapping requests cannot
extend it; current normal patterns resume afterward. Kernel triggers are not replaced.
Button actions are fixed and release-only; no public/web reboot or reset command exists.
See [button thresholds and recovery limits](indicators.md).

## Bus parameters

`bus_configure("can0", %{"enabled" => true, "bitrate" => 125000})` applies only
listen-only CAN configuration. `bus_configure("ttyS3", %{"enabled" => true})`
permits diagnostics without opening the UART; serial opt-in resets on service restart.
Only can0/can1 and ttyS3/ttyS4 are eligible. `bus_capture(port)` accepts a receive-only
capture once enabled. No caller-controlled duration or arbitrary device path exists.

`modbus_read("ttyS3", %{"unit" => 1, "function" => 3, "address" => 0, "count" => 2,
"authorized" => true})` sends one read, not a scan. Numbers may also be decimal strings;
booleans may be `"true"` / `"false"`. Authorization means the operator is authorized
and has ensured no other master is using the bus; it is not access control.

Acceptance is **not completion**. Observe `status.buses.operation`, `.error` and
`.result`. Each result includes `port`, `kind`, `completed_at` and bounded `data`:
`frames` for CAN, `hex`/`bytes` for serial, or `unit`/`function`/`address`/`count`/
`registers` for Modbus. One bus worker runs at a time. Configuration is non-atomic,
there is no automatic retry, and results/settings are not persisted. See
[bus limits, ownership and qualification](buses.md).

## Status and stale requests

`NervesGate.status/1` reads each domain independently; it is **not an atomic
cross-domain snapshot**. [`NervesGate.Status`](../lib/nerves_gate/status.ex) builds
the JSON-encodable v5 map without a process or cache:

- `version`, `system`: shape version and firmware.
- `network`: saved settings, pending trial, observed interfaces, readiness,
  recovery and structured errors.
- `connections`: port roles, cellular observations and subnet conflicts. `internet`
  includes `mode`, `selected` (preferred usable interface or nil), per-uplink
  `ethernet`/`cellular` connection states and overall `health`. `backup` is `active`
  while using 4G backup; otherwise it describes cellular connectivity/disablement.
- `remote_access`: sanitized Tailscale observations, routes, operation and error.
- `sharing`: confirmed equipment `subnet`, `enabled` (`true`, `false`, or `nil` for
  unknown), and `other_routes` left untouched by the on/off control.
- `equipment`: scoped neighbor observations, labels and scan status.
- `indicators`: simulated/available flags; button availability, armed state, hold feedback
  and last press; LED channel availability, current patterns, identification and retry
  state; recovery action, status and last error.
- `buses`: supported/simulated flags, detected ports and observed/configured state,
  one active operation, last bounded result and errors (idle observations refresh every five seconds).
- `capabilities`, `actions`: presentation-only availability, labels and reasons.
  Existing dotted action labels such as `"network.propose"` remain metadata;
  call `NervesGate.network_propose/2`, not a string dispatcher.

Equipment reachability remains unverified. Permitted Tailscale routes are unknown
(`nil`), not assumed empty. Advertised routes do not prove approval.

Confirm/cancel require the exact current trial ID. Only one trial and one remote
operation can run at a time. LiveViews compare drafts with their saved base before
submitting, but there is no cross-interface revision-token protocol. Network and
Remote connection commands remain independent. Equipment route changes hold the LAN
worker, and any advertised or uncertain routes block new LAN proposals. Sharing
never changes Tailscale running intent. No route result proves approval, isolation,
reachability or termination of existing sessions.

Sharing commands take only optional server options; callers do not supply a route,
site ID or confirmation flag. Enable requires the confirmed equipment link/address;
disable requires only the confirmed subnet and an available daemon. Disabling an
already-absent advertisement is safe. Other routes are never removed by this control.
Version 3 replaces v2's sharing scope/routes/uncertain projection; detailed uncertainty
remains in `remote_access.sharing`. There are no compatibility wrappers for the old
site-ID/route-argument commands. Version 4 removes `button_mode` and adds three-channel
LED patterns and physical recovery status. There is no compatibility button-mode API.

## Subscriptions

`NervesGate.subscribe/1` binds the caller to domain workflow metadata and existing
adapter observations. Notifications are `%PropertyTable.Event{}` or subsystem
notification tuples, not complete snapshots. Re-read status rather than applying
queued payloads. Subscribe before reading and after reconnecting or replacing an
entire domain instance. Subscriptions are removed on caller death. Unavailable
sources return an error; retry rather than assuming the subscription succeeded.

`NervesGateWeb.Observations` handles those notifications for connected LiveViews.
There are no duplicate PubSub lifecycle broadcasts. It retries failed subscriptions
after one second and coalesces notification bursts for 20 ms before re-reading. Panels share parent assigns; they add no subscriptions. Draft
editing, disclosures and countdowns stay in the UI; backend safety does not.

## Independent test instances

Pass domain server references (`:network`, `:remote`, `:equipment`, `:indicators`, `:buses`)
directly; no client object or `server:` wrapper:

```elixir
opts = [network: network_server, remote: remote_server]
:ok = NervesGate.subscribe(opts)
{:ok, id} = NervesGate.network_propose(settings, opts)
:ok = NervesGate.network_cancel(id, opts)
status = NervesGate.status(opts)
```

The former `NervesGate.Device` module, `dispatch/3`, `projection/1` and result/status
envelopes were removed. See [QEMU scenarios](../test/scenarios) for
public API examples and safety regressions, and [architecture](architecture.md)
for internal execution and recovery.

The current trusted-network deployment assumption, unauthenticated HTTP exposure,
CSRF and same-origin controls are unchanged. Future interfaces must establish
access control before invoking actions; availability is not authorization.
