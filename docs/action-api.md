# Device action API

Start at [`NervesGate.Device`](../lib/nerves_gate/device.ex). This is the public
boundary for LiveView, IEx/SSH and future adapters. Use its projection and dispatch
API rather than calling Network or Remote executors directly.

## Read, decide, dispatch

```elixir
alias NervesGate.{Config, Device}

:ok = Device.subscribe()
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

`dispatch(action_id, params \\ %{}, opts \\ [])` accepts only known string action
IDs and exactly their required string-keyed JSON parameters. Its result is:

```elixir
{:ok, %{result: result, projection: view}}
{:error, %{error: %{code: code, message: message}, projection: view}}
```

`network.validate` only normalizes/checks a draft. `network.propose` returns a
`trial_id`; console commands always require confirmation. Only a server adapter
with a verified USB `:access` context can request first-setup automatic saving.
Never construct this trusted option from request parameters or forwarded headers.

`remote.connect`, `remote.configure` and `remote.disconnect` return
`%{accepted: true}`. This means accepted, **not completed**. Follow
`view.remote_access.operation` and `.error` for completion. `remote.login_url`
returns `%{url: url_or_nil}`; enrollment URLs are private and must not be logged or
included in shared projections.

## Where actions go

[`Device.Actions`](../lib/nerves_gate/device/actions.ex) contains all eight action
IDs, labels, required fields, availability and explicit `route/3` clauses.

1. **Device** serializes requests, checks JSON parameters and optional revisions.
2. **Workflow** evaluates a pristine Runic graph: Actions prepares availability;
   Projection builds the read model; Actions decides the command.
3. **Device** executes the returned effect through **Network** or **Remote**.
4. **Network** rechecks readiness and owns durable saves, timeout and rollback.
   **Remote** validates again and runs slow Tailscale calls in a bounded task.
5. Device returns and publishes a fresh projection.

Policy evaluation has no hardware side effects. A workflow or browser crash cannot
abandon the network executor's rollback timer. Historical Runic facts do not
accumulate. There is no Runic Runner, Mnesia persistence or replayed effect queue.

### UI mapping

| Page / control | Device action |
| --- | --- |
| Network: Finish setup / Apply changes | `network.propose` |
| Network: Keep changes | `network.confirm` |
| Network: Restore previous settings | `network.cancel` |
| Tailscale: Connect Tailscale | `remote.connect` |
| Tailscale: Save device name | `remote.configure` |
| Tailscale: confirm disconnect | `remote.disconnect` |
| Tailscale: retrieve sign-in link after Connect | `remote.login_url` |

Form edits, disclosures and countdown rendering are local UI events. They do not
dispatch device actions. The Network form also checks its local draft before
proposing it; the backend always validates again.

## Projection and subscriptions

`Device.projection/0` is JSON-encodable and includes:

- `version`: schema version, currently 2.
- `revision`: opaque equality token, changing with state and gateway restart.
- `system`: firmware version and target.
- `network`: desired settings, pending trial, observed interfaces, readiness,
  recovery status and a structured error.
- `connections`: roles, cable/address/Internet observations and subnet conflicts.
- `remote_access`: Tailscale state, hostname, addresses, daemon version, advertised
  routes, redacted health messages and the current operation/error. No login URL.
- `capabilities`: implemented features; mobile and failover remain unavailable.
- `actions`: action ID → `label`, `required`, `enabled`, `reason`.

Equipment reachability is unverified. Permitted Tailscale routes are unknown
(`nil`), not assumed empty. Advertised routes do not prove approval.

Subscribe **before** reading; messages are `{:device, projection}` snapshots, not
a durable event log. Query again after reconnecting. A queued notification can
predate a synchronous command reply, so re-query on notifications rather than
rewinding the display to an older snapshot.

LiveViews/components use `Phoenix.LiveView.subscribe/3` from
[PR #4441](https://github.com/phoenixframework/phoenix_live_view/pull/4441):
`subscribe(socket, Device.topic(), &__MODULE__.handle_device/2)`. Callbacks return
an updated socket. LiveView owns cleanup and shares the underlying subscription
between components. The browser module is served from the same locked LiveView
Git dependency as the server. Other OTP clients use `Device.subscribe/0`.

## Concurrency and security

`expected_revision` optionally rejects stale requests. Confirm/cancel **always**
require the specific trial ID; an old request cannot accept a newer trial. Web
drafts also track their saved base to prevent overwriting another session's changes.

There is no exactly-once acknowledgment or durable command queue. On a lost reply,
timeout or `outcome_unknown`, **read the projection before retrying**. Tailscale
writes may partially complete even if the caller times out.

Availability and revisions are not authorization. The current unauthenticated UI
is for trusted networks only. Future remote APIs must add authentication and
authorization before forwarding commands to Device.
