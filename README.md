# Nerves Gate

A USB-configured gateway for private remote access to equipment, built with
Nerves 2 and Phoenix LiveView. EC100 is the primary target; x86_64 system support
is in progress. This repository is being built in small milestones.

The current milestone configures Ethernet connections, not remote access itself.
It separates the Internet connection from the equipment network, keeps USB for
local setup/recovery, and reports cable, address and Internet checks separately.

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

All targets share `mix.lock`; Mix selects dependencies through their `targets:`
options, without separate dependency versions for host and firmware.

EC100 currently uses the local checkout
`/home/n0gg1n/Development/Work/ism/dev/nerves_system_ec100`.
Tailscale is pinned to upstream revision `5e23c0f` in `mix.exs` and `mix.lock`.

EC100 retains its existing Nerves 2 system, bootloader, GPT storage layout and
A/B firmware contract. The x86 variant in `systems/x86_64` adds bridge and firewall
support to upstream commit `5d755dba94fff478eac2bfd90ba91d2e0025d4eb`.
Target system enablement/build verification is still in progress. See
[`systems/README.md`](systems/README.md) for the x86 source and changes.

## Firmware builds

Install the Tailscale daemon explicitly before building firmware:

```sh
export MIX_TARGET=ec100 # or x86_64
mix deps.get
mix tailscale.install rootfs_overlay/$MIX_TARGET/usr/sbin/tailscaled
mix firmware
```

`tailscale.install` selects the official static daemon for the target toolchain,
verifies its published SHA-256, and creates the destination directories. The
version is managed by `tailscale_ex` (currently **1.102.3**). Run it once per target,
and again when intentionally updating the daemon; **firmware builds do not run
it or download Tailscale**. Downloaded binaries are ignored by Git.

Firmware combines `rootfs_overlay/common` with `rootfs_overlay/<target>`. Keep the
ARM and x86 binaries separate. The device binary is `/usr/sbin/tailscaled`;
`rootfs_overlay/common/etc/iex.exs` prints `NervesMOTD` in serial or SSH IEx sessions.

Only the explicit installation step needs internet to download Tailscale on the
**build host**. No software is downloaded on the device, and the Tailscale CLI is
not needed. Kernel TUN support is required to start in kernel mode; starting the
daemon does not enroll the device or enable LAN routing.

Nerves 2 requires a source timestamp. Target builds use the latest Git commit's
Unix timestamp, or `SOURCE_DATE_EPOCH` when supplied (required for source archives
without Git history). EC100 firmware assembly has been verified with OTP 29;
this is not an EC100 boot or Tailscale connectivity test.

The standard Nerves startup guard sends Heart's required initialization handshake
and validates firmware after all expected OTP applications start. It does not
require internet or completed guided setup. Keep the startup guard enabled while
`HEART_INIT_TIMEOUT` is set; VM heartbeat monitoring alone does not send that handshake.

## Networking and settings

`NervesGate.Network` owns Ethernet settings through VintageNet. New gateways
leave both ports unassigned and **do not join them**. Guided setup offers:

- **Separate Internet and equipment ports**: either port gets Internet from an
  existing DHCP router. The other gets an unused static IPv4 address in the
  equipment subnet, without a default route. Both ports remain outside the bridge.
- **Explicit shared network**: both ports join `br0`, with DHCP or a static address
  and optional same-subnet router. Choose this only for one trusted network.
  STP is enabled; newly joined ports may take about 30 seconds to forward traffic.
  One missing port does not block the other.

Port 1/2 correspond to `eth0`/`eth1`. Static addresses support contiguous masks
(/1–/30). This software does not change equipment addresses, start an Ethernet
DHCP server, configure NAT, or enable equipment subnet forwarding. USB is never
part of a port-role change. Joining/splitting ports can interrupt Ethernet traffic.

Settings live in `/data/nerves_gate.json` (host: `tmp/dev/nerves_gate.json`). The
version-2 file is validated and written by fsync + atomic rename with mode 0600.
Version-1 files migrate **in memory** to the explicit shared arrangement, preserving
addresses and other settings; upgrading does not silently split an installed LAN.
The next explicit trial writes the migrated committed configuration before changing
interfaces. No credentials or observations are stored. Corrupt/unsupported files
are not overwritten.

Setup reviews changes, starts a 60-second trial, then requires confirmation. For
separate ports, readiness means the ports are present, configured, detached and
the equipment address matches; it does **not** require a cable or Internet lease.
Shared-network confirmation additionally requires an active member and bridge
address. Observed overlaps between Internet, equipment and USB subnets block
confirmation; later DHCP overlaps remain visible as warnings. Equipment or remote
reachability is never inferred from configuration readiness.

A GenServer, not the browser, owns the timeout. Only confirmed settings are on
disk; restarting the manager or rebooting cancels any trial. Failed apply/save
operations restore previous settings; rejected restore requests are retried.
VintageNet retries asynchronous interface failures. Keep USB connected throughout
setup; USB access does not imply Internet sharing or remote equipment access.

## Shared device commands and projection (CQRS)

All client adapters use `NervesGate.Device`, including LiveView and the IEx/SSH
console. The first domain is Ethernet setup; cellular, remote access and firmware
actions are not exposed until their executors are implemented.

```elixir
alias NervesGate.Device

:ok = Device.subscribe()                 # subscribe before reading
view = Device.projection()
view.actions["network.propose"]          # enabled, reason, label, required parameters

settings = %{
  "mode" => "ethernet",
  "internet_port" => "eth0",
  "equipment" => %{
    "ip_method" => "static",
    "static_ip" => "192.168.10.2", # choose an unused address in your equipment subnet
    "subnet_mask" => "255.255.255.0",
    "gateway" => nil
  }
}
Device.dispatch("network.validate", %{"network" => settings})
{:ok, %{result: %{trial_id: id}}} =
  Device.dispatch("network.propose", %{"network" => settings},
    expected_revision: view.revision)

# Only after checking connectivity; or use "network.cancel" to restore.
Device.dispatch("network.confirm", %{"trial_id" => id})
```

`projection/0` returns a JSON-encodable map with:

- `version`: projection schema version (currently 2).
- `revision`: opaque equality token; changes on state changes and gateway restart.
- `system`: firmware version and target.
- `network`: durable `desired` settings, trial `pending` settings, hardware
  `observed` state, readiness, recovery status and a structured error.
- `connections`: port roles, cable/address/Internet observations and subnet conflicts.
- `capabilities`: implemented features; mobile, failover and remote enrollment are
  currently unavailable.
- `remote_access`: unverified/unavailable; permitted routes are unknown (`nil`),
  not claimed empty. Existing daemon enrollment is not inspected yet.
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
LiveView follows Git `main`, with the exact commit locked in the shared
`mix.lock`, and requires Phoenix PubSub 2.4+. The browser module is served directly
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
before retrying. Availability and revisions are **not authorization**. The web UI
is temporarily reachable on every firmware IPv4 interface without authentication;
use only trusted networks. Future remote APIs must add an authentication/authorization
boundary.

## UI components

`NervesGateWeb.CoreComponents` provides the shared visual controls: panels,
buttons, labeled fields, status indicators, notices, setting rows and setup
progress. Port and addressing choices use visible native radio cards rather than
popup menus, retaining keyboard navigation and focus indicators. The same
components and CSS tokens are used throughout setup and the settings pages.

`ConnectionPanel` is a self-updating LiveComponent: it owns its managed device
subscription and reads the current projection on notifications. Multiple panels
share one underlying PubSub subscription per LiveView; removing the last panel
cleans it up. `NetworkStatus` only renders the supplied projection. Unsent form
edits remain owned by `SetupLive`, so status updates cannot replace a local draft.
All styles and SVG icons are local; no component JavaScript or external fonts are
required.

## Tests

```sh
mix test                           # host simulation, configuration, rollback, LiveView
scripts/test_bridge.sh             # real Linux bridge in isolated user/network/mount namespaces
```

The integration script requires Linux user namespaces, `ip`, `brctl`, `ifconfig`,
`udhcpc`, `dnsmasq`, `ping`, and `curl` in PATH. It never configures the workstation
LAN. It creates disposable LAN and USB peers and tests missing ports, hotplug,
bidirectional bridging, real DHCP, static IP changes, role transitions, port-role
reversal and rollback. It also fetches the real settings page from both Ethernet
peers before USB exists, then from USB and each separately addressed Ethernet port.
Its DHCP server exists only in the simulated existing LAN, not in the gateway. This is **not** a Nerves boot or EC100
hardware test.

## Current scope

The offline UI provides Overview, Equipment, Internet & backup, Remote access,
and Settings. Guided setup and all clients share the device projection and command
API. Host mode is explicitly labeled simulation; use
`NervesGate.Network.Host.simulate/1` in IEx to change observations.

Tailscale's OTP application starts automatically on firmware targets, supervising
`/usr/sbin/tailscaled` in kernel mode. Identity stays in `/data/tailscale_ex`; the
socket is under `/run`. Host simulation never starts or attaches to the
workstation's Tailscale daemon. This UI does not inspect or change an existing
manual Tailscale enrollment. Enrollment, permitted routes, remote verification,
equipment discovery, cellular, failover and firmware upload remain unfinished.
Saving local connections is **not** a claim that remote access works.

## Web access, USB setup and security

For now, both firmware targets serve the full web UI on **all IPv4 interfaces**
at port **4000**. Open `http://<gateway-address>:4000/settings` using a reachable
USB, Ethernet/bridge or kernel-mode VPN address. The listener starts without USB
and also accepts connections on interfaces added later. This does not configure
an address, enroll a VPN or enable equipment routing. Host preview remains bound
to `127.0.0.1:4000` only.

For independent local recovery, connect EC100's USB setup connection and open
`http://<gateway-usb-address>:4000/setup`. `VintageNetDirect` derives the USB /30
subnet at runtime; there is no hardcoded device IP. For diagnostics over serial or
SSH, inspect `VintageNet.get(["interface", "usb0", "addresses"])` for its address.
Its small DHCP server is confined to USB, never either Ethernet port. USB does
not automatically share your laptop's Internet connection.

The UI is **unauthenticated**: anyone who can reach port 4000 can change settings.
Use only trusted networks; do not expose this temporary listener to the public
Internet. There is no ownership/password step yet. Same-origin and CSRF checks
remain enabled; these are not authentication. Changing Ethernet settings may
interrupt that browser connection, so keep USB or serial recovery available.
SSH recovery is key-only; set `NERVES_GATE_SSH_KEYS` to public keys at build time.
This HTTP policy does not change SSH's interface exposure.

The kernel must expose `usb0`; application configuration cannot create a missing
USB gadget. The local EC100 checkout includes fixed-role USB restoration
(`d375405`), and USB has been operator-reported working. The new listener, cable
reconnection and port transitions still need **on-device verification**. Keep
serial recovery available; host simulation and Linux namespace tests are not a
firmware/hardware qualification.
