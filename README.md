# NervesGate

NervesGate is an x86_64 Nerves gateway with one firmware-tagged configuration:

```text
Internet → Tailnet → Cluster
```

There is no database, setup phase, or per-subsystem settings journal. Tailscale
owns its daemon state under `/data/tailscale/`; every application setting lives
in the firmware slot files:

```text
/data/settings-a.json
/data/settings-b.json
```

Each file records its firmware slot, UUID, and version. The running firmware
uses its matching file. Legacy `setup.json`, `network.json`, `cluster.json`,
`device.json`, and `settings-change.json` files are removed. On the first boot
of newly installed slot B, the known settings from slot A are copied and
retagged for B; the reverse applies when A
is newly installed. This preserves a known configuration for each firmware
rollback target.

## Remote-access transaction

`NervesGate.DeviceState.Server` is the sole local public-state authority.
`/commissioning` builds a guarded remote-access candidate:

```text
/data/settings-candidate.json
```

The candidate is applied temporarily, but the running slot file remains
unchanged. A configured gateway's update must be kept from a fresh Tailnet
connection before the selected timeout, which defaults to one minute.
First-time setup has no automatic timer. **Keep settings** atomically promotes
the candidate over `settings-a.json` or `settings-b.json`. Application restart,
device reboot, **Revert now**, or timer expiry reapplies the accepted slot file
and removes the candidate. Failed rollback effects retain the candidate and are
retried. Tailscale auth keys are used once and never written to any settings
file.

An unconfigured gateway starts the ordered Internet → Tailnet → Cluster editor.
A configured gateway opens `/commissioning` directly on separate Internet,
Tailnet, and Cluster forms. One page-wide **Revert unless kept after** selector
applies to all three forms. Merely opening or editing a form has no effect; only
its explicit **Update** button creates and applies a scoped candidate. While an
update is temporary, a compact notification shows the countdown and **Keep
changes**, **Reopen through Tailnet**, and **Revert changes** actions while the
forms remain visible but locked. Internet and Tailnet forms warn that the browser
may disconnect, retain a client-side applying/reconnecting indicator during the
request, and identify the notification as proof that the gateway is reachable
again. Scoped updates leave all other accepted settings unchanged. There is no
`/settings` route or separate setup workflow. The local JSON commissioning
transport maps one-to-one onto the same guarded `NervesGate` commands used by
LiveView.

## Backend model

`NervesGate.Backend` starts stable runtime infrastructure followed by a
restartable public-state subtree:

```text
Task/Tailscale runtime
      ↓
DeviceState.Server
      ↓
resource owners → Gateway.Configuration FSM
      ↓                 ↓
Dependencies         Alarms.Runtime
      ↓
DeviceState.Replica FSM × remote gateway
      ↓
NervesGate.Session × connected client
```

The architecture uses only Command, Event, and State. Imperative commands go to
the subsystem that owns the affected private state. Runtime completions and
observations return as past-tense events. Owners report complete secret-free
public slices to `DeviceState.Server`, which validates ownership, deduplicates,
assigns a revision, and broadcasts the event. Runtime effects are supervised
implementation machinery, not another domain abstraction. Finitomata is reserved
for protocols with meaningful legal phases; ordinary observers and reconcilers
are supervised GenServers.

Credentials, private candidate data, and effect references never enter
DeviceState. Its configuration slice exposes only secret-free accepted and
candidate projections plus the user-visible countdown. Each remote gateway replica owns its
boot ID, revision, retry, liveness lease, and connection metadata. It installs
one atomic snapshot and then reduces ordered events pushed by the source. The
source sends a lightweight heartbeat every second; missing the 2.5-second lease
marks the retained snapshot stale without polling full state or waiting for
Erlang's node-down timeout. A boot-ID change or revision gap requests a fresh
snapshot immediately; events are never buffered for replay.

## Code organization

`NervesGate` is the strict boundary between clients and the backend. A client
connects once, receives a session PID plus complete initial fleet state, and is
then pushed complete updates. The session owns snapshot installation, reducer
application, revisions, and resynchronization. LiveViews and controllers submit
commands through the thin facade and do not know about supervisors, settings
files, Tailscale, or subsystem processes.

Backend code is organized by bounded context rather than by module count:

```text
nerves_gate.ex                   thin session and command facade
nerves_gate/session.ex           per-client live state projection
nerves_gate/{internet,tailnet,cluster,ssh,subnet_router,commissioning}.ex
                                 one resource owner per subsystem
nerves_gate/*/{status,runtime}.ex
                                 public projections and imperative boundaries
nerves_gate/*/alarms.ex          subsystem-owned alarm policy and remedies
nerves_gate/gateway/             guarded settings FSM, validation, persistence
nerves_gate/device_state/        pure State projection, event server, replicas
nerves_gate/fsm.ex               small Finitomata defaults
nerves_gate/fsm/{listener,effect,diagnostics}.ex
                                 commit hooks, bounded effects, and FSM queries
nerves_gate_web/                 rendering, forms, routing, and access policy
```

A support module stays in its subsystem file unless it is a substantial pure,
platform, or policy boundary worth testing independently. Alarm graphs remain
separate from state machines because they have a different concern and
lifecycle, while still living under their owning subsystem. This keeps related
code discoverable without mixing frontend concerns into the backend.

`tailscale_ex` owns `tailscaled`, command scheduling, typed status, health,
profiles, preferences, readiness, and subscriptions. `Tailnet` projects
that typed state and owns Tailnet usability, but never repairs or restarts the
daemon. `Gateway.Settings`, `Gateway.Persistence`, and `Gateway.Runtime` remain
small configuration boundaries. A single change signal inhibits expected
connectivity alarms while a remote-access candidate is active.

Kernel forwarding is immutable platform policy in `/etc/sysctl.conf`, loaded by
`nerves_runtime` before this application starts.

## Commissioning

Connect to the isolated Wi-Fi/spare Ethernet interface and open:

```text
http://192.168.77.1/commissioning
```

Commissioning follows the runtime dependencies:

1. configure gateway identity and DHCP or static Internet, then verify link,
   address, route, DNS, and HTTPS;
2. enroll in Tailscale with a one-use auth key;
3. select singular cluster mode or a public Tailnet-visible cluster group.

The gateway display name is a friendly replicated label used in NervesGate
status pages and gateway lists. It does not change the stable device ID, setup
Wi-Fi SSID, Tailscale hostname, IP address, or Erlang node name.

During first-time setup, each dependency is applied before the next step is
available and all three remain one reversible candidate. Applied steps do not
reopen: revert and start again if an earlier value is wrong. After Cluster is
applied, reopen `/commissioning` through the candidate Tailnet address and press
**Keep settings**. A plain GET never mutates settings.

On a configured gateway, `/commissioning` opens all three scoped forms directly.
Press **Update Internet**, **Update Tailnet**, or **Update Cluster** to apply only
that submitted subsystem. Then keep the temporary update from a fresh Tailnet
connection before its countdown expires, or let it restore accepted settings
automatically. Production restricts the dashboard to Tailscale. Development
firmware keeps QEMU's isolated local dashboard forwards available.

## Subnet routing

Subnet routing is an ordinary owner command, not part of commissioning. The
local dashboard can dynamically advertise one or more IPv4 or IPv6 CIDRs with
`tailscale set`, update them, or withdraw all advertisements. Enabling or
disabling the subnet router never changes the selected Tailnet profile or the
gateway's remote-management connection.

The desired enabled state and canonical routes live in the active firmware-slot
snapshot. Persistence is the acceptance boundary; `SubnetRouter` then converges
asynchronously and publishes advertised, approved, and primary state through the
public event stream. There is no resource-change saga, candidate, confirmation,
or revert timer. Application failures raise a noncritical alarm and a bounded
remedy asks the owner to reconcile again; remote gateway access is unchanged.

## Remote IEx

The dashboard can enable or disable a NervesSSH IEx console. Only the boolean
`ssh_enabled` setting is persisted. `SSH` starts NervesSSH only after `Tailnet`
reports a concrete IPv4 address in Tailscale's `100.64.0.0/10`
range, and it binds port 22 to that exact address. Tailnet loss blocks and stops
the listener; reconnection or an address change reconciles it automatically.

Persistent listener failures raise an SSH alarm only while Internet and Tailnet
are healthy. Its remedy reapplies the accepted `ssh_enabled` intent; it cannot
change the listener address policy or any Tailnet setting.

## Lifecycle machines, alarms, and healing

Only staged configuration, Internet application, cluster-peer protocols, and
remote replica synchronization use Finitomata. Finitomata embeds each executable
state diagram in its module documentation, and ExDoc renders those declarations
as Mermaid diagrams during `mix docs`. Tailnet, SSH, Cluster coordination,
subnet routing, commissioning, and replica scanning are ordinary GenServers
because their state is observed or reconciled reality rather than a transition
protocol. `DeviceState.State.apply_event/2` remains a pure projection and
storage remains synchronous rather than being modeled as a controller.

`Alarms.Runtime` atomically subscribes to the same public snapshot/event stream
as every other consumer. Each subsystem owns its raw signals, managed conditions,
public alarms, and bounded heal callbacks. The dependency graph reports the highest actionable
root cause: Internet suppresses Tailnet and every downstream alarm; Tailnet
suppresses cluster, SSH, and subnet-router alarms; storage, commissioning, and
active configuration changes suppress expected operational alarms. Raw signals
remain truthful while public alarms are inhibited. Remedy declarations are
registered by the alarm runtime rather than compiled into alarm definitions.

Alarm remedies never clear alarms directly. They reapply accepted state and
request a fresh observation; only that observation can clear the alarm. Internet,
cluster, SSH, subnet routing, and commissioning access have idempotent remedies.
Storage failure, Internet instability, and required commissioning remain human
actions. Tailnet healing is limited to a fresh typed observation—login, profile
switching, `down`, and daemon manipulation remain prohibited.

Client authentication is delegated to Tailnet policy with OTP SSH's
`no_auth_needed` option. No developer public key is embedded in firmware,
Tailscale SSH is never enabled, and wildcard or LAN/WLAN keyless listeners are
rejected before NervesSSH starts.

## Dashboard and replicated state

The main page at `http://<tailscale-ip>/` provides:

- local and replicated gateway state;
- live, degraded, and stale connection states;
- last-known alarms for disconnected gateways;
- Internet → Tailnet → Cluster status;
- dynamic local subnet-router controls and route approval status;
- Tailnet-only Remote IEx controls and listener status;
- canonical connectivity evidence and device identity;
- visible public cluster groups and automatic peer connections.

Each gateway is the sole sequencer for its canonical
`NervesGate.DeviceState.State`. Connected gateways join every peer's independent
snapshot/event stream and retain stale snapshots after disconnection. Changes
are pushed and reduced locally; one-second source heartbeats detect silent
partitions in about two to three seconds. Heartbeats carry only identity and
revision metadata, do not mutate canonical state, and do not consume revisions.
No fleet leader is required because each stream mutates only its owning device.
Credentials, candidate internals, task metadata, and logger history are never
replicated.

```elixir
{:ok, session, initial_fleet} = NervesGate.connect()

receive do
  {:nerves_gate_state_changed, ^session, fleet} ->
    fleet
end

:ok = NervesGate.disconnect(session)
```

## Firmware

The local Nerves system enables kernel TUN, IPv6 policy routing, netfilter, and
A/B root filesystems. Tailscale `1.102.3` is pinned and verified during firmware
construction:

```sh
mix deps.get
mix nerves_gate.bundle_tailscale
MIX_TARGET=x86_64 mix firmware
```

Firmware output:

```text
_build/x86_64_dev/nerves/images/nerves_gate.fw
```

The system supports explicit `Nerves.Runtime.revert/0`. Automatic GRUB trial
boot fallback remains separate system-level work.

## Local QEMU environment

The host-only control plane lives in its own Mix project under
`tools/nerves_gate_qemu`. Start it from the repository root with:

```sh
mix nerves_gate.dev
```

Then open `http://qemu.localhost:4000/`. The task starts only the standalone
QEMU OTP application and its endpoint, router, PubSub, session, and assets. It
has no dependency on the gateway application or Nerves runtime stack, so gateway
routes such as `/commissioning` and `/api/status` are not served on port `4000`.

The control plane manages a variable topology, shows combined QMP and gateway
status, embeds isolated gateway dashboards, and can disconnect or heal each
uplink without touching its commissioning NIC. Lifecycle actions run
asynchronously.

```sh
mix nerves_gate.qemu help
mix nerves_gate.qemu setup --count 3 --rebuild  # build current source, recreate disks, start
mix nerves_gate.qemu setup --count 3            # reuse the existing firmware artifact
mix nerves_gate.qemu commission                  # commission and converge every existing VM
mix nerves_gate.qemu integration --count 3 --rebuild  # fresh cluster plus resilience suite
mix nerves_gate.qemu add
mix nerves_gate.qemu remove M04
mix nerves_gate.qemu status
mix nerves_gate.qemu observe          # runtime, discovery, distribution, and replicas
mix nerves_gate.qemu observe --json
mix nerves_gate.qemu logs             # follow all serial logs
mix nerves_gate.qemu stop
mix nerves_gate.qemu restart          # preserves disks and settings slots
mix nerves_gate.qemu reset            # deletes disks
```

Topology is stored atomically in `tmp/qemu/topology.json`. Machine `M01` uses
port `4001`, `M02` uses `4002`, and so on. Gateway dashboards use isolated
hostnames such as `http://m01.localhost:4001/`; commissioning is available at
`http://m01.localhost:4001/commissioning`.

Each VM has unique identifiers, a NAT uplink, an isolated commissioning NIC,
QMP and serial sockets, and a persistent disk under `tmp/qemu`. Gateways discover
peers over the Tailnet and connect when their public groups match. `observe`
reads each development VM's versioned, secret-free `nerves_gate.status.v3`
projection through its local forward; use `watch -n 2 mix nerves_gate.qemu observe`
to follow convergence. Loss, latency, and blackhole semantics are reserved for
an isolated TAP/netem
uplink layer; deterministic QMP link-down faults work with the current SLIRP
networking.

Put a reusable, pre-authorized Tailnet key in the process environment or the
repository's ignored `.env` file:

```sh
NERVES_GATE_TAILSCALE_AUTH_KEY=tskey-auth-...
```

`commission` invokes the guarded backend commands through the local JSON
transport; it does not run a browser or depend on rendered forms. The key is
sent only to the Tailnet command and is never written to settings or test
output. The easiest complete run is:

```sh
mix nerves_gate.qemu integration --count 3 --rebuild
```

It builds current firmware, recreates the requested disks, commissions every
VM, waits for a fully replicated mesh, and runs unkept-update rollback,
disconnect/reconnect, hard restart, and stop/start scenarios. Tests use only the
backend command transport and `nerves_gate.status.v3`; browser rendering has
separate focused LiveView tests. Assertions verify accepted settings survive,
offline replicas retain last-known state, and new DeviceState boot IDs replace
stale snapshots.
Host-side faults are always healed during cleanup.

To rerun the integration tests against an already commissioned topology:

```sh
cd tools/nerves_gate_qemu
mix test --include integration test/integration/qemu_fault_test.exs
```

Tailscale grants must allow gateway tags to reach other gateways on TCP port `80`
for group discovery and ports `4369` and `43769` for Erlang distribution.
Ordinary dashboard clients should not receive the distribution-port grants.

## Verification

```sh
mix ci
```
