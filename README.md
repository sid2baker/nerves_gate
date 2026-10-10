# Nerves Gate

A two-port Ethernet remote-access gateway for EC100 and x86_64, built with
Nerves 2 and Phoenix LiveView. This repository is being rebuilt in small milestones.

## Development

Use Elixir 1.20 and the Erlang/OTP major version required by the target system.

```sh
mix deps.get
mix test
mix phx.server
# http://localhost:4000
```

Host mode must never modify the workstation's network. All browser assets are
local and checked in. To rebuild CSS: `cd assets && npm ci && npm run build`.
Node.js is not needed to compile firmware or use the setup page.

## Targets

```sh
MIX_TARGET=ec100 mix deps.get
MIX_TARGET=ec100 mix compile
MIX_TARGET=x86_64 mix deps.get
MIX_TARGET=x86_64 mix compile
```

Development currently uses these local checkouts in `mix.exs`:

- EC100: `/home/n0gg1n/Development/Work/ism/dev/nerves_system_ec100`
- Tailscale: `/home/n0gg1n/Development/Work/opencode/tailscale_ex`

EC100 retains its existing Nerves 2 system, bootloader, GPT storage layout and
A/B firmware contract. The x86 variant in `systems/x86_64` adds bridge and firewall
support to upstream commit `5d755dba94fff478eac2bfd90ba91d2e0025d4eb`.
Target system enablement/build verification is still in progress. See
[`systems/README.md`](systems/README.md) for the x86 source and changes.

## Firmware builds

`MIX_TARGET=ec100 mix firmware` (or `MIX_TARGET=x86_64 mix firmware`) automatically
runs the `tailscale_ex` task `mix tailscale.install` with the selected target.
The task selects the official static `tailscaled` for the target toolchain and
verifies its published SHA-256. Each target has a separate generated overlay at
`_build/<target>_<env>/tailscale_rootfs`; the device binary is `/usr/sbin/tailscaled`.
The separate, checked-in `rootfs_overlay/etc/iex.exs` prints `NervesMOTD` when
opening a serial or SSH IEx session. The Tailscale version is managed by
`tailscale_ex` (currently **1.102.3**).

Installation requires internet on the **build host** on each firmware build.
No software is downloaded on the device, and the Tailscale CLI is not needed.
Kernel TUN support is required to start in kernel mode; starting the daemon does
not enroll the device or enable LAN routing.

Nerves 2 requires a source timestamp. Target builds use the latest Git commit's
Unix timestamp, or `SOURCE_DATE_EPOCH` when supplied (required for source archives
without Git history). EC100 firmware assembly has been verified with OTP 29;
this is not an EC100 boot or Tailscale connectivity test.

The standard Nerves startup guard sends Heart's required initialization handshake
and validates firmware after all expected OTP applications start. It does not
require internet or completed guided setup. Keep the startup guard enabled while
`HEART_INIT_TIMEOUT` is set; VM heartbeat monitoring alone does not send that handshake.

## Networking and settings

`NervesGate.Network` owns Ethernet settings through VintageNet. Both `eth0` and
`eth1` always belong to `br0`; a missing or disconnected port does not block the
other. Only the bridge gets a management address. DHCP is the default; static
IPv4, a contiguous subnet mask (/1–/30), and an optional same-subnet router are
supported. No Ethernet DHCP server or NAT is configured. STP is enabled to reduce
loop risk; a newly connected port may take about 30 seconds to forward traffic.
The Layer 2 bridge stays up during management IP changes.

Settings live in `/data/nerves_gate.json` (host: `tmp/dev/nerves_gate.json`). The
version-1 file is validated and written by fsync + atomic rename with mode 0600.
No credentials or discovery status are stored in it. Corrupt/unsupported files
are not overwritten. Setup reviews changes, starts a 60-second trial, then asks
you to check equipment connectivity and explicitly confirm. Confirmation requires
an active bridge and matching address. Internet access is not required.

A GenServer, not the browser, owns the timeout. Only confirmed settings are on
disk; restarting the manager or rebooting cancels any trial. Failed apply/save
operations restore previous settings; rejected restore requests are retried.
VintageNet retries asynchronous interface failures, which remain visible in
bridge status. Keep an independent recovery path when changing your local IP.

## Shared device commands and projection (CQRS)

All client adapters use `NervesGate.Device`, including LiveView and the IEx/SSH
console. The first domain is Ethernet setup; cellular, remote access and firmware
actions are not exposed until their executors are implemented.

```elixir
alias NervesGate.Device

:ok = Device.subscribe()                 # subscribe before reading
view = Device.projection()
view.actions["network.propose"]          # enabled, reason, label, required parameters

Device.dispatch("network.validate", %{"network" => %{"ip_method" => "dhcp"}})
{:ok, %{result: %{trial_id: id}}} =
  Device.dispatch("network.propose", %{"network" => %{"ip_method" => "dhcp"}},
    expected_revision: view.revision)

# Only after checking connectivity; or use "network.cancel" to restore.
Device.dispatch("network.confirm", %{"trial_id" => id})
```

`projection/0` returns a JSON-encodable map with:

- `version`: projection schema version (currently 1).
- `revision`: opaque equality token; changes on state changes and gateway restart.
- `system`: firmware version and target.
- `network`: durable `desired` settings, trial `pending` settings, hardware
  `observed` state, readiness, recovery status and a structured error.
- `actions`: stable string IDs with availability, a disabled reason (`code` and
  `message`), a display label and required string-keyed parameters.

Commands return `{:ok, %{result: result, projection: view}}` or
`{:error, %{error: %{code: code, message: message}, projection: view}}`.
`network.validate` only normalizes/checks a local draft; it does not save or apply
anything. The server revalidates every command. `expected_revision` is optional;
confirmation/cancellation always require the specific trial ID, never “whichever
trial is current”. Unsent form edits, wizard steps and countdown rendering stay
local to each client.

Changes publish `{:device, projection}` through Phoenix PubSub. These are full
snapshots, not a durable event log. Subscribe then query on connection/reconnection.
A notification queued before a synchronous command reply may be older than the
reply; LiveView re-queries on notifications rather than rewinding its display.
Other adapters should do the same when mixing replies and notifications.

LiveView uses `Phoenix.LiveView.subscribe/3` from
[PR #4441](https://github.com/phoenixframework/phoenix_live_view/pull/4441):
`subscribe(socket, Device.topic(), &__MODULE__.handle_device/2)`. The callback
returns an updated socket, rather than a `handle_info/2` tuple. LiveView owns the
subscription lifecycle (including LiveComponent cleanup), and disconnected renders
do not subscribe. IEx and other OTP clients still use `Device.subscribe/0`.
LiveView follows Git `main`, with the exact commit locked in the host and EC100
lockfiles, and requires Phoenix PubSub 2.4+. The browser module is served directly
from that same LiveView dependency, keeping client and server versions aligned.

`Device.Workflow` runs a pure Runic graph: network policy feeds both the projection
and command-decision branches. `Device` serializes requests and executes the
resulting effect descriptions through the existing `Network` OTP process. That
process remains the safety boundary for fresh readiness checks, durable saves,
timeouts and retrying rollback, even if the gateway/workflow crashes. A pristine
graph is reused for each evaluation; historical facts do not accumulate. Settings
remain in the existing atomic JSON file—this is CQRS, not event sourcing or Runic
Runner/Mnesia persistence. Runic is pinned to a reviewed alpha Git revision.

There is no durable command queue, automatic effect replay, or exactly-once
acknowledgement. On a timeout, disconnect or `outcome_unknown`, read the projection
before retrying. Availability and revisions are **not authorization**. The trusted
network access limitation below still applies; future remote APIs must add an
authentication/authorization boundary.

## Tests

```sh
mix test                           # host simulation, configuration, rollback, LiveView
scripts/test_bridge.sh             # real Linux bridge in isolated user/network/mount namespaces
```

The integration script requires Linux user namespaces, `ip`, `brctl`, `ifconfig`,
`udhcpc`, `dnsmasq`, and `ping` in PATH. It never configures the workstation LAN.
It creates two disposable LAN peers and tests one/missing/two ports, hotplug,
gateway-to-peer traffic, transparent peer-to-peer traffic, real DHCP, static IP
changes and rollback. Its DHCP server exists only in the simulated existing LAN,
not in the gateway. This is **not** a Nerves boot or EC100 hardware test.

## Current scope

The offline LiveView setup and dashboard share the device projection and command
API and update from discovery automatically. Host mode is explicitly labeled simulation; use
`NervesGate.Network.Host.simulate/1` in IEx to change observations. Tailscale will
use the refactored `sid2baker/tailscale_ex` LocalAPI interface. Its OTP application
starts automatically on firmware targets, supervising `/usr/sbin/tailscaled` in
kernel mode. Identity stays in `/data/tailscale_ex`; the socket is under `/run`.
Host simulation does not start or attach to the workstation's Tailscale daemon.
Enrollment UI, subnet forwarding, cellular and firmware upload remain unfinished.
For development, the target web listener binds to **all IPv4 interfaces on port
4000** (USB, Ethernet, and other reachable device addresses). Open
`http://<device-ip>:4000`. The UI is **unauthenticated**: anyone who can reach it
can change network settings. Use only on trusted networks until access controls
are added. LiveView same-origin and CSRF checks remain enabled. Host development
still binds only to `127.0.0.1:4000`.
SSH recovery is key-only; set `NERVES_GATE_SSH_KEYS` to public keys at build time.

EC100 boot configures `usb0` with `VintageNetDirect`, independently of `br0` and
LAN configuration trials. Its small DHCP server is confined to USB, never either
Ethernet port. The kernel must expose `usb0`; this configuration cannot create a
missing USB gadget. USB provides a recovery network for key-only SSH and local
browser access on port 4000, without laptop internet sharing.

The local EC100 checkout includes fixed-role USB restoration (`d375405`). USB0
enumeration/reconnection and USB1 modem transport remain unverified. Keep serial
and Ethernet recovery available; do not depend on USB provisioning yet.

An operator-reported EC100 boot shows `br0` configured by DHCP with VintageNet
reporting `:internet`. This confirms that reported boot's bridge addressing and
internet detection, not two-port forwarding, failover or USB recovery.
