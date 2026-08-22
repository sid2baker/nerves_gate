# NervesGate

NervesGate is an x86_64 Nerves gateway with a deliberately small initialization
flow:

```text
Internet → Tailnet → Cluster
```

The persisted commissioning phase is stored in `/data/setup.json`. Verified
Internet settings live in `/data/network.json`, the optional public cluster
group lives in `/data/cluster.json`, editable device information and its change
history live in `/data/device.json`, and Tailscale owns `/data/tailscale/`.
Guarded changes use an atomic `/data/settings-change.json` rollback journal.
There is no database.

`NervesGate.Setup` only orchestrates commissioning choices. Internet, Tailnet,
and Cluster managers reconstruct and repair their own runtime state after boot.

## Backend model

The application supervisor has four responsibilities: PubSub, the backend,
Phoenix Presence, and the web endpoint. `NervesGate.Backend` makes the runtime
ordering explicit:

```text
Settings.ChangeControl → maintenance scope / one-change lock
                ↓
Device profile / commissioning access
                ↓
Internet.Manager → Internet.Monitor
                ↓
Tailnet.Manager  → Tailnet.Observer → Tailnet.Configuration
                ↓
Cluster.Manager
                ↓
DeviceState.Server → DeviceState.Client
```

Each mutable concern has one owner. Managers own persisted configuration and
local process lifecycle. Monitors and observers publish runtime facts. Alarm
modules translate those facts into actionable conditions. `Setup` sends
commissioning commands but owns no runtime health, and `DeviceState` is the
secret-free read model shared with already-connected gateways.

Kernel forwarding is immutable gateway platform policy in `/etc/sysctl.conf`,
loaded by `nerves_runtime` before this application starts. It is intentionally
not a Tailscale library side effect.

## Replicated device state

Each gateway is the sole writer of its own canonical
`NervesGate.DeviceState.Data`. Every change is represented as an operation and
first applied by `NervesGate.DeviceState.Server` through the pure
`Data.apply_operation/2` transition function. The server then broadcasts the
accepted operation in order, so connected clients apply the same function and
keep identical local `%Data{}` copies with minimal messages.

A joining client receives the current data atomically. Boot IDs, revisions,
connection freshness, monitors, retries, and operation buffers remain separate
transport metadata. Revision gaps trigger a fresh join, while disconnected
clients retain stale last-known data. `Cluster.Manager` discovers visible
NervesGate peers from Tailscale and connects them; `DeviceState.Client` only
replicates from nodes that distribution has already connected.

Only identity, firmware, connectivity state, public cluster group, and safe
active alarms are in `Data`. Tailscale credentials, repair state, pending
rollback internals, and logger history remain private to their owning gateway.

```elixir
NervesGate.device_state()
NervesGate.replicas()
```

## Initialization

Connect to the isolated setup Wi-Fi/spare Ethernet interface and open:

```text
http://192.168.77.1/commissioning
```

1. Configure DHCP or static Internet. A candidate is persisted only after link,
   address, route, DNS, and HTTPS checks pass. Failure restores the previous
   known-good configuration.
2. Supply a Tailscale auth token. It is used for the enrollment call and never
   written to disk.
3. Select singular mode, join a visible cluster group, or create a public group
   name. Distribution is bound to the Tailscale IP and visible NervesGate peers
   in the same group are connected automatically. Tailnet grants are the
   security boundary for the Erlang distribution ports.

The same operations have a small Elixir API:

```elixir
NervesGate.configure_internet(%{"ip_address" => "dhcp"})
NervesGate.configure_tailscale("tskey-auth-…")
NervesGate.configure_cluster()              # singular mode
NervesGate.configure_cluster("plant_floor") # public cluster group
```

They are also exposed as commissioning-only API endpoints:

```text
POST /api/setup/internet
POST /api/setup/tailscale
POST /api/setup/cluster
```

For static Internet, send `ip_address`, `prefix_length`, `gateway`, and `dns`.
Use request bodies, not query strings: query strings leak auth tokens into
browser history, proxies, and access logs. `/commissioning` shows only the
current required step. Completion atomically persists `:ready`; setup operations
then reject further writes and `/` becomes the tailnet-only status dashboard.

## Dashboard

The main page at `http://<tailscale-ip>/` is tailnet-only. It provides:

- a fleet switcher for this gateway and every previously connected gateway;
- clear live, degraded, and stale connection states;
- the last replicated alarms and revision for an offline gateway;
- the dependency-ordered Internet → Tailnet → Cluster state for each gateway;
- a cluster-wide count of distinct dashboard visitors;
- local diagnostics, editable device naming, and recovery access;
- read-only configured Internet, Tailnet, and cluster state;
- visible Tailscale gateway candidates and their public group state.

Post-commissioning configuration is isolated at `/settings`. Internet,
Tailnet, and Cluster each own their candidate, validation, confirmation timer,
and rollback behavior. `Settings.ChangeControl` only serializes changes,
persists the rollback journal, and inhibits expected dependency alarms. A
candidate must be confirmed from a fresh management connection within five
minutes or its subsystem restores the persisted known-good configuration.

The LiveView follows the same operation model as the backend. On connection it
joins the local `DeviceState.Server`, keeps canonical `%DeviceState.Data{}` in
`socket.private`, applies ordered operations locally, and assigns only a small
rendering projection. Remote copies come from `DeviceState.Client`. Rendering is
split into `StatusLive.Render`, a pure `StatusLive.View`, and reusable Core,
Gateway, and Setup components styled with Tailwind CSS.

Name changes are recorded with timestamp, actor name, and tailnet IP in
`/data/device.json`. The profile schema already reserves a `documents` list for
later versioned documentation support.

Production setup networks cannot open the completed dashboard. Development
firmware keeps the loopback-forwarded QEMU dashboard available.
`NervesGate.Setup.enable_recovery_access/1` re-enables isolated access without
deleting the known network or Tailscale state.

## Firmware

The local Nerves system enables kernel TUN, IPv6 policy routing, and netfilter.
Tailscale `1.102.3` is pinned and verified during firmware construction:

```sh
mix deps.get
mix nerves_gate.bundle_tailscale
MIX_TARGET=x86_64 mix firmware
```

Firmware output:

```text
_build/x86_64_dev/nerves/images/nerves_gate.fw
```

The custom x86_64 system currently provides A/B slots and explicit
`Nerves.Runtime.revert/0`, but its GRUB configuration does not yet implement an
automatic trial-boot fallback. Settings rollback is therefore operational now;
firmware remote-witness validation remains separate system-level work.

## Local three-node environment

One Mix task provides two fresh three-node environments without TAP setup:

```sh
mix nerves_gate.qemu setup       # manual initialization testing
mix nerves_gate.qemu functional  # automatic DHCP, Tailscale, and singular setup
mix nerves_gate.qemu status
mix nerves_gate.qemu stop
mix nerves_gate.qemu restart     # preserve the current disks
```

Functional mode safely reads `NERVES_GATE_TAILSCALE_AUTH_KEY` from the ignored
`.env` file. Setup mode never consumes the credential.

Development dashboards are forwarded to the root URLs; first-run commissioning
uses the corresponding `/commissioning` path:

```text
M01  http://127.0.0.1:4001/   commissioning: http://127.0.0.1:4001/commissioning
M02  http://127.0.0.1:4002/   commissioning: http://127.0.0.1:4002/commissioning
M03  http://127.0.0.1:4003/   commissioning: http://127.0.0.1:4003/commissioning
```

Development firmware keeps the isolated setup interface active after commissioning,
so these loopback-only forwards continue to serve each dashboard. Production
firmware still disables setup access and restricts management to Tailscale.
Functional mode also prints and records each tailnet dashboard URL; remote browsers
must be connected to that same tailnet. `mix nerves_gate.qemu status` reports both
locations once commissioning is complete.

Each VM has a unique UUID and MAC addresses, a NAT Internet uplink, an isolated
setup NIC, and a persistent 4 GiB disk in `tmp/qemu`. Gateways query visible NervesGate peers over the Tailnet discovery endpoint and
connect automatically when their public groups match. Tailscale grants must
allow mutual TCP access between gateway tags to EPMD port `4369` and the
configured distribution port `43769`; ordinary dashboard clients should not be
granted those ports.

The external integration witness remains available in
`test/integration/three_node_test.exs` for tailnet/distribution restart checks.

## Verification

```sh
mix ci
```
