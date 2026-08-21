# NervesGate

NervesGate is an x86_64 Nerves gateway with a deliberately small initialization
flow:

```text
Internet → Tailnet → Cluster
```

The current web compatibility phase is stored in `/data/setup.json`. Verified
Internet settings live in `/data/network.json`, the optional cluster cookie is
stored with restrictive permissions in `/data/cluster.json`, editable device
information and its change history live in `/data/device.json`, and Tailscale
owns `/data/tailscale/`. Writes are atomic and there is no database.

`NervesGate.Setup` only orchestrates commissioning choices. Internet, Tailnet,
and Cluster managers reconstruct and repair their own runtime state after boot.

## Initialization

Connect to the isolated setup Wi-Fi/spare Ethernet interface and open:

```text
http://192.168.77.1/
```

1. Configure DHCP or static Internet. A candidate is persisted only after link,
   address, route, DNS, and HTTPS checks pass. Failure restores the previous
   known-good configuration.
2. Supply a Tailscale auth token. It is used for the enrollment call and never
   written to disk.
3. Select singular mode or provide a cluster cookie. A cookie enables Erlang
   distribution bound to the Tailscale IP. It authorizes connections but does
   not discover or automatically connect peers.

The same operations have a small Elixir API:

```elixir
NervesGate.configure_internet(%{"ip_address" => "dhcp"})
NervesGate.configure_tailscale("tskey-auth-…")
NervesGate.configure_cluster()            # temporary singular-mode compatibility
NervesGate.configure_cluster("shared-secret") # cluster-enabled backend API
```

They are also exposed as API endpoints, not separate pages:

```text
POST /api/setup/internet
POST /api/setup/tailscale
POST /api/setup/cluster
```

For static Internet, send `ip_address`, `prefix_length`, `gateway`, and `dns`.
Use request bodies, not query strings: query strings leak auth tokens into
browser history, proxies, and access logs. The root page shows only the current
required step. Once setup is complete, the same URL renders the dashboard and
requires a tailnet source address.

## Dashboard

The main page at `http://<tailscale-ip>/` is tailnet-only. It provides:

- a top-left node menu linking to every discovered gateway homepage;
- the current Tailscale name and IP;
- a cluster-wide count of distinct people currently viewing one or more gateway dashboards;
- setup, Internet, cluster, alarm, and runtime status;
- an editable device display name.

Name changes are recorded with timestamp, actor name, and tailnet IP in
`/data/device.json`. The profile schema already reserves a `documents` list for
later versioned documentation support.

Local setup networks cannot open the dashboard. Loopback remains allowed for
host development and on-device diagnostics. `NervesGate.Recovery.activate/0`
re-enables isolated recovery access without deleting the known network or
Tailscale state.

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

## Local three-node environment

One Mix task provides two fresh three-node environments without TAP setup:

```sh
mix nerves_gate.qemu setup       # manual initialization testing
mix nerves_gate.qemu functional  # automatic DHCP, Tailscale, and clustering
mix nerves_gate.qemu status
mix nerves_gate.qemu stop
mix nerves_gate.qemu restart     # preserve the current disks
```

Functional mode safely reads `NERVES_GATE_TAILSCALE_AUTH_KEY` from the ignored
`.env` file. Setup mode never consumes the credential.

While commissioning, the setup page is forwarded to:

```text
M01  http://127.0.0.1:4001/
M02  http://127.0.0.1:4002/
M03  http://127.0.0.1:4003/
```

These localhost forwards intentionally close when commissioning finishes and
its isolated setup interface is disabled. Functional mode prints and records
each tailnet-only dashboard URL; the browser must be connected to that same
tailnet. `mix nerves_gate.qemu status` reports the appropriate setup or tailnet
location instead of presenting the closed localhost forward as a dashboard.

Each VM has a unique UUID and MAC addresses, a NAT Internet uplink, an isolated
setup NIC, and a persistent 4 GiB disk in `tmp/qemu`. Enroll all three into the
same tailnet to exercise the real node menu and cluster behavior.

The external integration witness remains available in
`test/integration/three_node_test.exs` for tailnet/distribution restart checks.

## Verification

```sh
mix ci
```
