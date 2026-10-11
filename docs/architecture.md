# Backend architecture

NervesGate uses Jido v3 for network trial policy, ordinary OTP for bounded I/O,
and existing subsystem observations for reads. No central state/projection server,
application persistence journal, connectivity retry graph or AI dependency.

## Where to start

1. [`lib/nerves_gate.ex`](../lib/nerves_gate.ex): named public functions, status,
   subscriptions and result types. LiveView and IEx use this stateless module.
2. [`status.ex`](../lib/nerves_gate/status.ex) and
   [`error.ex`](../lib/nerves_gate/error.ex): pure status interpretation and sanitized
   errors. Commands return plain results; status is a separate read.
3. [`network/actions.ex`](../lib/nerves_gate/network/actions.ex): first-USB-setup
   auto-save policy. [`network/agent.ex`](../lib/nerves_gate/network/agent.ex)
   declares its Jido reconciliation route; the plugin supplies fresh trial state.
4. [`network/runtime.ex`](../lib/nerves_gate/network/runtime.ex): command admission
   and replies, one temporary trial, independent deadline and bounded worker.
5. [`remote.ex`](../lib/nerves_gate/remote.ex): one GenServer for asynchronous
   Tailscale operations. No agent or additional runtime layer.

## State ownership

| Owner | Responsibility |
| --- | --- |
| VintageNet | Saved/applied Ethernet configuration, hotplug, addresses, routing and observations |
| Tailscale | Identity, preferences, daemon state, routes and enrollment |
| Network Agent | Decide whether first verified USB setup should await readiness, auto-save or cancel |
| Network Runtime | Command admission/replies, RAM trial, live effect guards, deadline, serial work and rollback |
| Remote | One bounded daemon worker and sanitized operation/error metadata |
| Equipment | Bounded passive neighbor polling, scope-local inventory and persistent labels; monitors the runtime-owned active scan |
| PropertyTable | Existing subsystem properties plus ephemeral workflow/host-simulation observations |
| NervesGate / Status | Named public functions and on-demand interpretation; no stored read model |
| LiveView | Drafts, presentation, lifecycle-bound subscriptions and command submission |

```text
LiveView / IEx → NervesGate named API
                       ├─ network → Network Runtime → worker → VintageNet
                       │                  ↕ live trial / automatic decision
                       │             Jido USB auto-save policy
                       └─ remote → Remote GenServer → worker → Tailscale

Subsystem properties + workflow metadata → LiveView → fresh status read
```

Pure validation calls `Config.validate_network/1` directly. Status reads domains
independently, not as an atomic cross-domain snapshot. Equipment entries from a
different scope are suppressed immediately by the pure status builder. There are no
optimistic revision tokens; exact trial IDs and serialized operations protect the
workflow. LiveViews also compare saved draft bases. See [action-api.md](action-api.md).

## Supervision and work ownership

Application `rest_for_one` order is PubSub (Phoenix infrastructure), Registry,
workflow PropertyTable, managed `NervesGate.Jido`, host simulators (host only),
Network, Remote, Equipment, then Endpoint. Firmware dependencies supervise VintageNet and
Tailscale themselves.

Network is a `rest_for_one` supervisor: runtime first, permanent Jido AgentServer
second. Runtime restart kills its linked worker, reloads saved settings and applies
them before accepting trials. An agent-only crash leaves the independent deadline
alive and interrupts the active trial through an owner monitor. Failed restoration
blocks new proposals and retries; unreadable saved configuration fails closed.

Network commands use ordinary `GenServer.call/3` with a single 15-second timeout.
The runtime remains responsive while its worker runs and uses `GenServer.reply/2`
after application, saving or restoration. OTP handles late replies; there is no
custom alias/monitor reply protocol. A caller timeout is an unknown outcome, not
cancellation or permission to replay. Manual commands do not wait for a Jido turn.

Jido's action decides only automatic USB progression. Plugin dispatch submits typed
effects after AgentServer commits, without waiting for hardware. Every effect
checks live runtime state again. No caller handle enters agent state. The
postponed-signal queue is bounded to 32.

Expected failures return error tuples. Unexpected worker exceptions are logged and
reach the coordinator through task `:DOWN` messages; adapters do not catch them.
Supervision handles coordinator failures. Only the public API translates
`GenServer.call` exits into unavailable/unknown-outcome results, keeping exceptions
and throws from programming errors visible.

Workers are linked, bounded and killed/joined before restoration or another operation.
VintageNet has its own asynchronous work, so the adapter retains its configuration
and bridge-membership settlement barrier. Restoration forces a reapply through
VintageNet's public deconfigure/configure APIs when necessary: a killed configure
caller can leave the configuration property updated before the interface receives
it, making an ordinary identical-config call a no-op. USB is never part of LAN
operations.

## Network policy and persistence

`Network.Actions.Advance` evaluates current admission, not queued payload state:

| Current trial | Decision |
| --- | --- |
| Applying, saving or restoring | No overlapping effect |
| Manual, applied | Await explicit confirmation |
| First verified USB setup, ready | Request `auto_confirm` |
| First verified USB setup, conflicting addresses | Request `auto_cancel` |
| First verified USB setup, not ready | Request `await`, then wait for readiness |

The runtime vetoes stale IDs, expired deadlines, overlapping work, automatic effects
on manual trials, and changed readiness/conflicts. It does not choose a different
normal-path action when a decision has become stale. A suspended agent cannot
prevent rollback, but cannot cause auto-save either.

Readiness changes send an empty `network.reconcile` hint. Pending trials also poll
once a second to repair missed notifications. Hints carry no snapshots, sequence
numbers or incarnation tokens: admission always reads live state. Idle observation
bursts do not produce Jido hints.

A proposal applies with `persist: false`. Manual confirmation has a **60-second**
window; first server-verified USB setup has a **15-second** auto-save bound.
Confirmation explicitly calls VintageNet's persistence API for each LAN interface:
`VintageNet.configure/3` skips identical configurations before saving and does not
propagate save errors, so reconfiguring an already-applied trial is insufficient.

Only mode and port-role labels supplement VintageNet's normalized settings. The
form is reconstructed from those settings, not a second saved profile. There is
no old JSON importer or compatibility format. Host simulation keeps saved settings
in memory.

**Saving interfaces is not a transaction.** A failure, interruption or power loss
partway through confirmation may leave partially saved settings. Runtime rollback
restores the prior applied configuration, not an atomic disk snapshot. A subsequent
restart uses whatever VintageNet saved. This is an intentional simplification;
there is no durable trial journal, commit marker or cross-interface crash recovery.
Keep USB/serial recovery available. See [networking.md](networking.md).

## Remote operations

One GenServer admits one bounded asynchronous daemon operation. Acceptance is not
completion. Timeout/crash stops the worker; restart observes the daemon and never
replays a mutation. Daemon-side work may already have completed, so read status
before retrying. Connect/rename patch hostname and `accept_dns: false`, preserving
omitted preferences. Disconnect calls `down/0`, not logout; connect resumes an enrolled
profile with `up/0` or starts login when needed. Startup does not rewrite the profile.

Equipment sharing holds the existing LAN worker while Remote merges or withdraws
one 4via6 advertisement and verifies preference readback. LAN proposals are blocked
by advertised or uncertain 4via6 routes; rollback remains independent. Initial route
observation uses a read-only Controller mailbox barrier so earlier accepted work
finishes before admission. No mutation is replayed. There is no second forwarding
state, custom firewall, launcher or lifecycle coordinator. Route changes do not
change running intent. Preference readback is not a traffic-termination guarantee;
see [networking.md](networking.md#equipment-sharing).

Status reads sanitized adapter observations directly. Login URLs are private
queries, validated against official HTTPS login hosts, and never retained in
server state, public status or properties. Health URLs and raw errors are redacted.
The workflow property contains only a status-change hash, not another daemon mirror.

## Equipment observations

Equipment polls only the confirmed static equipment interface, reading the Linux
neighbor table over rtnetlink. A bounded passive worker cannot send probes. An
explicit ARP scan is admitted by Network Runtime, which owns the sole active LAN
worker and blocks trials until that scan finishes. Equipment monitors that worker;
it does not create a second scan task. Timeout/restart closes its raw socket and
clears scan progress without invoking LAN restoration. Interface names and source
addresses are derived from confirmed settings and live readiness, never submitted
by the browser. USB is not eligible.

Inventory and labels are each bounded to 256 entries. Firmware labels use a small
validated JSON file with synchronous temporary-file/rename writes; host labels
stay in an Agent. They are scoped by confirmed interface, subnet, gateway address
and MAC. The IP is not treated as a global or authenticated identity. A changed
scope clears observations, not saved labels. Invalid saved labels block writes
rather than silently replacing a corrupt file. See [ui.md](ui.md) for scan limits.

## Button and LED

`Indicators` is one small GenServer, independent of network and remote commands.
It owns a monotonic five-second identify deadline, restores the previous raw LED
value, and rejects overlaps. Failed restoration blocks identification and retries
on the five-second device-availability poll. Graceful shutdown also attempts restoration;
there is no durable recovery journal for abrupt process/VM loss or power failure.

The EC100 adapter only touches `/sys/class/leds/ec100:run/brightness`, accepts raw
0/1 with `max_brightness=1`, and refuses active kernel triggers. Physical polarity
and the second LED mapping are unverified. Input discovery requires exactly one
`gpio-keys` device with KEY_PROG1 (148) in the EC100 32-bit capability bitmap.
`InputEvent` supplies events; disconnects clear availability and discovery retries.
Only a rising press is accepted, with a one-second debounce/rate limit. Repeats and
holds cannot extend identification. The two modes, disabled and identify, are
memory-only and default to disabled after any service restart. No reset or network
action exists. Other targets are unsupported; the host adapter uses memory only.
Existing PropertyTable observations carry status hints, not another event bus.

## Notifications

The UI subscribes to existing VintageNet/Tailscale properties and workflow metadata,
coalesces bursts for 20 ms, then rereads status. No duplicate PubSub lifecycle event
bus exists. Subscribe before reading and after reconnecting; caller death removes
subscriptions. Panels reuse parent assigns. Missing observation sources return an
error rather than claiming a successful subscription; connected LiveViews retry
in one second. Domain polling rebinds subscriptions and repairs missed hints;
notifications are best effort, not an event log.

There is no Alarmist/Connectivity agent that repeatedly rereads cached status.
Internet observations already belong to VintageNet. The application does not
perform automatic DHCP restarts, VPN reconnects, DNS resets, failover or enrollment.

## Web interface

Operations and commissioning have separate pages: Equipment offers explicit scans
and local labels; Overview and Remote access display current status. Settings
contains the network and Tailscale editors plus button/LED controls.
First-time and subsequent network configuration use the same form. The old setup
and redirect-only Internet routes are removed, not retained as compatibility paths.

Read-only pages use the existing observation module’s `on_mount` hook. Editors
keep their draft-aware refresh callbacks. Navigation lives inside the LiveView
layout so current-page markers update on live navigation. A pending network trial
remains visible across pages, with a direct link to keep or restore it.
Equipment uses the same property subscriptions, without another lifecycle notification system.
See [ui.md](ui.md) for scope and future hardware interfaces.

## Dependencies

The immutable v3 source set in `mix.exs` / `mix.lock` is:

| Dependency | Pin |
| --- | --- |
| Jido (`3.0.0-beta.1`) | `agentjido/jido@90763478104f1edbf0afcfcf9444621c3f9755e8` |
| Jido Action (`3.0.0-beta.12`) | `agentjido/jido_action@8e9b3f7b268e175091b0eb3720bab3b8633d3c24` |
| Zoi | `mikehostetler/zoi@2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9` |
| Jido's internal Runic engine | `mikehostetler/runic@6b1c8c85d2d560a7ff5da6c3a417254c5d2b85b6` |
| Jido Signal / PropertyTable | locked `3.0.0-beta.4` / `0.3.4` |

**Approved exception:** current Jido v3 requires Runic internally even for individual
Actions. These compatible source pins resolve its unavailable Hex alpha dependency
set without forking the executor. NervesGate has no direct Runic API calls, graphs
or workflows, and no AI dependencies. Complete removal from the dependency graph
is not claimed. See the
[release requirements](https://hex.pm/api/packages/jido/releases/3.0.0-beta.1) and
[pinned executor](https://github.com/agentjido/jido_action/blob/8e9b3f7b268e175091b0eb3720bab3b8633d3c24/lib/jido_exec.ex).

## Removed machinery and verification

The Device dispatcher/client/status envelope became named root functions and pure
Status/Error modules. AtomicFile, TrialStore, Recovery, lifecycle Signals,
Connectivity/Alarmist, the Remote agent stack, custom command reply protocol and
revision protocol were removed, not renamed. Network keeps Jido for USB auto-save
policy. `.reach.exs` enforces
public API boundaries, pure actions/selectors and no direct Runic usage.

Tests cover named APIs, LiveView behavior, stale IDs, USB access verification,
conflicts, linked worker termination, suspended/crashed agents, retrying restoration,
subsystem persistence, deliberate partial-save behavior, logged task failures,
caller timeout/late-reply behavior and subscription recovery/cleanup. Separate integration scripts exercise isolated Linux LAN/USB
peers and a private userspace Tailscale 1.104.1 daemon. Firmware builds do not flash
a device; no on-device boot or physical power-loss test is implied.

Jido v3 is beta and its internal Runic dependency emits upstream compiler warnings.
The independently reproduced OTP 29/MuonTrap `:epipe` command-runner race remains
unfixed; see [networking.md](networking.md). Host tests do not prove physical cable,
USB or storage behavior. The UI remains unauthenticated for trusted networks, with
CSRF/same-origin safeguards unchanged. No new hardware capability is implied.
