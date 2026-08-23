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

`NervesGate.DeviceState.Server` is the sole local settings and public-state
authority. `/commissioning` builds one complete remote-access candidate through
Internet, Tailnet, and cluster steps:

```text
/data/settings-candidate.json
```

The candidate is applied temporarily, but the running slot file remains
unchanged. A configured gateway's change must be accepted from a fresh
management connection before the selected timeout, which defaults to one minute.
First-time setup has no automatic timer. Acceptance atomically promotes the
candidate over `settings-a.json` or `settings-b.json`. Application restart,
device reboot, or explicit rejection always deletes the candidate and reapplies
the running slot file; configured changes do the same when their timer expires.
Tailscale auth keys are used once and never written to any settings file.

An unconfigured gateway starts the three-step editor immediately. A configured
gateway first shows only **Change settings** and the auto-revert time. There is
no `/settings` route, separate setup workflow, or commissioning API.

## Backend model

`NervesGate.Backend` starts runtime layers in dependency order:

```text
Commissioning.Access
        ↓
Internet.Manager → Internet.Monitor
        ↓
Tailnet.Manager  → Tailnet.Observer → SSH.Manager
        ↓
Cluster.Manager
        ↓
DeviceState.Server → DeviceState.Client
```

Every physical gateway runs one `DeviceState.Server` as the sole writer for its
own state and one `DeviceState.Client` holding peer replicas. The server keeps
firmware settings, candidates, credentials, tasks, and timers private. Only its
secret-free `DeviceState.Data` is changed through ordered pure reducer
operations and sent to joined peers. Clients apply the same operations but never
execute the returned local actions.

The subsystem managers own runtime processes only. They do not persist their
own configuration or implement candidate state machines. `Gateway.Settings`,
`Gateway.Persistence`, and `Gateway.Effects` are private helpers used by the
server. A single change signal inhibits expected connectivity alarms while a
remote-access candidate is active.

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

Each dependency is applied before the next step is available, while all three
remain one reversible candidate. Completed Internet and Tailnet steps stay
accessible for further editing without undoing downstream runtime changes.
After the final step, reconnect through the candidate management path and accept
it. Configured changes must be accepted before their countdown expires.
Production then restricts the dashboard to Tailscale. Development firmware keeps
QEMU's isolated local dashboard forwards available.

## Subnet routing

Subnet routing is an ordinary remote operation, not part of commissioning. The
local dashboard can dynamically advertise one or more IPv4 or IPv6 CIDRs with
`tailscale set`, update them, or withdraw all advertisements. Enabling or
disabling the subnet router never changes the selected Tailnet profile or the
gateway's remote-management connection.

The desired enabled state and canonical routes live in the active firmware-slot
snapshot. A successful write produces one ordered public reducer operation; its
local action applies the routes through Tailscale. Runtime observations return
as further operations containing advertised, approved, and primary routes.
There is no candidate, confirmation, or revert timer. Application failures raise
a noncritical alarm and are retried after `tailscaled` reconnects; remote gateway
access is unchanged.

## Remote IEx

The dashboard can enable or disable a NervesSSH IEx console. Only the boolean
`ssh_enabled` setting is persisted. NervesSSH is started by `SSH.Manager` only
after `Tailnet.Observer` reports a concrete IPv4 address in Tailscale's
`100.64.0.0/10` range, and it binds port 22 to that exact address. Tailnet loss
stops the listener; reconnection or an address change reconciles it automatically.

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
- local diagnostics and device naming;
- visible public cluster groups and automatic peer connections.

Each gateway is the sole writer and sequencer for its canonical
`NervesGate.DeviceState.Data`. Connected gateways join every peer's independent
operation stream and retain stale snapshots after disconnection. No fleet leader
is required because each stream mutates only its owning device. Credentials,
candidate internals, task metadata, and logger history are never replicated.

```elixir
NervesGate.configuration()
NervesGate.device_state()
NervesGate.replicas()
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

## Local three-node environment

```sh
mix nerves_gate.qemu setup
mix nerves_gate.qemu status
mix nerves_gate.qemu stop
mix nerves_gate.qemu restart   # preserves disks and settings slots
mix nerves_gate.qemu reset     # deletes disks
```

QEMU URLs:

```text
M01  http://127.0.0.1:4001/   commissioning: http://127.0.0.1:4001/commissioning
M02  http://127.0.0.1:4002/   commissioning: http://127.0.0.1:4002/commissioning
M03  http://127.0.0.1:4003/   commissioning: http://127.0.0.1:4003/commissioning
```

Each VM has unique identifiers, a NAT uplink, an isolated commissioning NIC, and
a persistent disk under `tmp/qemu`. Gateways discover peers over the Tailnet and
connect when their public groups match. Tailscale grants must allow gateway tags
to reach TCP ports `4369` and `43769` while ordinary dashboard clients should
not receive those grants.

## Verification

```sh
mix ci
```
