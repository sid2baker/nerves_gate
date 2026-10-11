# Device action API

[`NervesGate.Device`](../lib/nerves_gate/device.ex) is the stateless public boundary
for LiveView, IEx/SSH and future interfaces. It translates eight stable string
commands into domain APIs backed by Jido v3 Actions. It starts no process and
stores no projection or command history.

## Read, decide, dispatch

```elixir
alias NervesGate.{Config, Device}

:ok = Device.subscribe()                 # bind before the initial read
view = Device.projection()

settings = %{
  "mode" => "ports",
  "eth0" => %{"role" => "internet", "address" => Config.address_defaults()},
  "eth1" => nil
}

Device.dispatch("network.validate", %{"network" => settings})
{:ok, %{result: %{trial_id: id}}} =
  Device.dispatch("network.propose", %{"network" => settings},
    expected_revision: view.revision)

# Check connectivity before keeping the trial. Or call network.cancel.
Device.dispatch("network.confirm", %{"trial_id" => id})
```

`dispatch(action_id, params \\ %{}, opts \\ [])` accepts known string action IDs
and exactly their required string-keyed JSON parameters. Process identifiers,
references, structs and invalid UTF-8 are not accepted. Results remain:

```elixir
{:ok, %{result: result, projection: view}}
{:error, %{error: %{code: code, message: message}, projection: view}}
```

| Command | Parameters | Result / meaning |
| --- | --- | --- |
| `network.validate` | `network` | `%{network: normalized}`; pure validation, no running agent required |
| `network.propose` | `network` | `%{trial_id: id}` after durable preparation and successful apply |
| `network.confirm` | `trial_id` | `%{}` after the confirmed decision is durable |
| `network.cancel` | `trial_id` | `%{}` after successful restoration |
| `remote.connect` | `hostname` | `%{accepted: true}`; begin connection/enrollment |
| `remote.configure` | `hostname` | `%{accepted: true}`; request a name change |
| `remote.disconnect` | none | `%{accepted: true}`; request sign-out |
| `remote.login_url` | none | `%{url: url_or_nil}`; explicit private query |

Console proposals require confirmation. Only trusted server code can supply the
`:access` context used to verify first setup through USB. Never derive this option
from request parameters or forwarded headers. All subsequent changes require
confirmation, including those made through USB. For immediate-ready first USB
setup, the proposal reply waits for durable auto-save. If application is still
settling, the agent acknowledges the pending trial and later commits when ready,
without browser intervention. Conflicts and persistence failures are not reported
as successful auto-saves. The runtime independently enforces the 15-second bound.

Remote acceptance is **not completion**. Observe `view.remote_access.operation`
and `.error`. One bounded asynchronous operation can run at a time. Private
login URLs are delivered directly to the requester, never placed in agent state,
PropertyTable, public facts or projections. Do not log or share them.

## Execution and outcomes

1. Device validates the wire shape and translates to a public domain operation.
2. A Jido AgentServer routes a request Signal to its schema-validated Action.
   Plugin admission reads current domain safety state; the Action makes a pure
   decision and returns candidate agent state plus typed effect directives.
3. After agent commit, the Plugin dispatches directives to an infrastructure
   runtime. It rechecks revisions and safety at the serialized effect boundary.
4. The runtime owns bounded, linked workers. Network directives return after
   submission so the agent can coordinate subsequent applied/readiness facts.
   The private caller acknowledgment still waits for the relevant durable/apply/
   restore boundary; Remote replies after accepting its worker.
5. Significant outcomes become Jido Signals. Device returns an on-demand view,
   not a cached snapshot. Draft validation uses `Jido.Exec.run/4` directly.

Errors have stable string codes and actionable messages; raw adapter exceptions
are not public data. Invalid input, stale revisions/IDs, conflicting work,
configuration readiness and recovery failures remain distinct. On timeout,
agent death or `outcome_unknown`, **read current state before deciding whether to
retry**. A caller timeout does not cancel an admitted Jido command. Network's
independent watchdog/journal restores unconfirmed work; daemon-side writes may
finish after their caller dies. Uncertain client commands are not automatically
replayed. Network recovery may retry restoration; there is no exactly-once
acknowledgment or durable command queue.

## Read shape and revisions

`Device.projection/0` retains its compatibility name and JSON-encodable v2 shape.
It combines two independently read domains; it is **not an atomic cross-domain
snapshot**. [`Device.Selectors`](../lib/nerves_gate/device/selectors.ex) is pure.

- `version`, `revision`, `system`: shape version, opaque concurrency token, firmware.
- `network`: requested/saved settings, pending trial, observed interfaces,
  readiness, recovery and structured errors.
- `connections`: roles, cable/address/Internet observations and subnet conflicts.
- `remote_access`: sanitized Tailscale observations, routes, operation and error.
- `capabilities`, `actions`: supported features and presentation-only availability,
  labels and required parameters; never authorization or execution policy.

Equipment reachability remains unverified. Permitted Tailscale routes are unknown
(`nil`), not assumed empty. Advertised routes do not prove approval.

An optional `expected_revision` checks **only the commanded domain**, both at
admission and at the effect boundary. A Network trial changes its token; ordinary
link/lease updates do not invalidate a form draft. Remote observations and
operations change the Remote token. Changes in the other domain do not reject
an otherwise current command. Runtime restart changes that domain's incarnation.
Treat tokens as opaque; confirm/cancel always require the exact current trial ID.
LiveViews also compare the draft's saved base to prevent overwriting another
session's configuration.

## Subscriptions and UI mapping

`Device.subscribe/0` binds the caller directly to domain workflow metadata and
adapter PropertyTable sources. Notifications are `%PropertyTable.Event{}` or the
subsystem's translated notification tuples, **not `{:device, snapshot}`**. Treat
all payloads as hints: re-read current state rather than overwriting a newer
command reply with a queued observation. Subscribe before reading and re-subscribe
after reconnecting or replacing an entire domain instance. Registries remove
subscriptions on caller death.

`NervesGateWeb.Observations` binds connected LiveViews to these properties and to
`network:events` / `remote:events` with lifecycle-managed
`Phoenix.LiveView.subscribe/3` ([PR #4441](https://github.com/phoenixframework/phoenix_live_view/pull/4441)).
It coalesces bursts for 20 ms before re-reading. Connection panels receive parent
assigns; they do not add subscriptions. Neither AgentServer handles nor Jido
implementation details enter the view layer. Alarmist subscriptions belong to the
Connectivity input lifecycle; these pages have no separate alarm display.

| Page / control | Device command |
| --- | --- |
| Network: Finish setup / Apply changes | `network.propose` |
| Network: Keep changes | `network.confirm` |
| Network: Restore previous settings | `network.cancel` |
| Tailscale: Connect Tailscale | `remote.connect` |
| Tailscale: Save device name | `remote.configure` |
| Tailscale: confirm disconnect | `remote.disconnect` |
| Tailscale: retrieve sign-in link | `remote.login_url` |

Draft edits, disclosures and countdowns remain local UI events. The backend always
validates again. Tests can inject independent domain supervisors with
`Device.new(network: network, remote: remote)` and pass that value as `server:`;
this constructs a facade, not a competing state process.

The unauthenticated UI remains restricted by its trusted-network deployment
assumption, CSRF and same-origin controls. Future interfaces must add their own
authentication and authorization before forwarding commands. Availability and
revision tokens are not access control.
