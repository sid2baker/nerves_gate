# NervesGate public API

Start with [`lib/nerves_gate.ex`](../lib/nerves_gate.ex). It contains the named,
documented, typed functions used by LiveView and IEx/SSH. There is no public
string dispatcher, client struct, facade process or cached status server.
Jido and the domain runtimes are implementation details.

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
| `equipment_share(site_id, unique_confirmed, opts)` | `:ok` after 4via6 advertisement readback |
| `equipment_unshare(route, opts)` | `:ok` after exact route withdrawal readback |
| `identify(opts)` | `:ok` once the five-second run-LED identification starts; observe completion/restoration |
| `button_mode(mode, opts)` | `:ok`; `"disabled"` or `"identify"`, until indicators-service restart |
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
If application is still settling, the agent acknowledges the pending trial and
later commits when ready. Conflicts and persistence failures are not successful
auto-saves. The runtime independently enforces the 15-second USB bound and the
60-second manual confirmation window. Confirmation saves interfaces individually;
interrupted or failed persistence can leave a partial save. There is no durable
trial journal or multi-interface transaction. See [networking](networking.md).

Remote acceptance is **not completion**. Observe `status.remote_access.operation`
and `.error`. One bounded asynchronous operation runs at a time. Enrollment URLs
are delivered only by `remote_login_url/1`, never placed in status, server state
or subscribed properties. Do not log or broadcast them.

Network commands use one standard OTP call with a 15-second timeout and deferred
hardware-completion replies. Manual commands do not wait for the policy agent.
On `outcome_unknown`, **read status before deciding whether to retry**. Caller
timeout does not cancel an admitted command. Network recovery remains independent
of the caller; a daemon mutation may complete after its caller dies. Uncertain
commands are not automatically replayed. There is no exactly-once acknowledgment
or durable command queue.

Identify preserves the previous raw LED value. Overlapping requests cannot extend it.
Only the mapped EC100 run LED is supported; active kernel triggers are not replaced.
Button mode defaults to disabled and is never persisted. No reset action exists.
See [button and LED safety limits](ui.md#button-and-led).

## Status and stale requests

`NervesGate.status/1` reads each domain independently; it is **not an atomic
cross-domain snapshot**. [`NervesGate.Status`](../lib/nerves_gate/status.ex) builds
the JSON-encodable v2 map without a process or cache:

- `version`, `system`: shape version and firmware.
- `network`: saved settings, pending trial, observed interfaces, readiness,
  recovery and structured errors.
- `connections`: port roles, cable/address/Internet observations and conflicts.
- `remote_access`: sanitized Tailscale observations, routes, operation and error.
- `sharing`: eligible equipment scope, displayed routes and uncertain mutations.
- `equipment`: scoped neighbor observations, labels and scan status.
- `indicators`: simulated/available flags, button mode and last press, LED identification,
  restoration-pending state and errors.
- `capabilities`, `actions`: presentation-only availability, labels and reasons.
  Existing dotted action labels such as `"network.propose"` remain metadata;
  call `NervesGate.network_propose/2`, not a string dispatcher.

Equipment reachability remains unverified. Permitted Tailscale routes are unknown
(`nil`), not assumed empty. Advertised routes do not prove approval.

Confirm/cancel require the exact current trial ID. Only one trial and one remote
operation can run at a time. LiveViews compare drafts with their saved base before
submitting, but there is no cross-interface revision-token protocol. Network and
Remote connection commands remain independent. Equipment route changes hold the LAN
worker, and advertised or uncertain 4via6 routes block new LAN proposals. Sharing
never changes Tailscale running intent. No route result proves approval, isolation,
reachability or termination of existing sessions.

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

Pass domain server references (`:network`, `:remote`, `:equipment`, `:indicators`)
directly; no client object or `server:` wrapper:

```elixir
opts = [network: network_supervisor, remote: remote_server]
:ok = NervesGate.subscribe(opts)
{:ok, id} = NervesGate.network_propose(settings, opts)
:ok = NervesGate.network_cancel(id, opts)
status = NervesGate.status(opts)
```

The former `NervesGate.Device` module, `dispatch/3`, `projection/1` and result/status
envelopes were removed. See [`api_test.exs`](../test/nerves_gate/api_test.exs) for
public API examples and safety regressions, and [architecture](architecture.md)
for internal execution and recovery.

The current trusted-network deployment assumption, unauthenticated HTTP exposure,
CSRF and same-origin controls are unchanged. Future interfaces must establish
access control before invoking actions; availability is not authorization.
