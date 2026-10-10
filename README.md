# Nerves Gate

A USB-configured gateway for private remote access to equipment, built with
Nerves 2 and Phoenix LiveView. EC100 is the primary target; x86_64 system support
is in progress. This repository is being built in small milestones.

Configure Ethernet connections and connect the gateway to Tailscale from a simple
local UI. Internet and equipment ports stay separate, USB remains available for
recovery, and cable, address and Internet checks are reported separately. Tailscale
connects the gateway itself; equipment subnet routing is not enabled by this UI.

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
Tailscale is pinned to upstream revision `3a859e7` in `mix.exs` and `mix.lock`.

EC100 retains its existing Nerves 2 system, bootloader, GPT storage layout and
A/B firmware contract. The x86 variant in `systems/x86_64` adds bridge and firewall
support to upstream commit `5d755dba94fff478eac2bfd90ba91d2e0025d4eb`.
Target system enablement/build verification is still in progress. See
[`systems/README.md`](systems/README.md) for the x86 source and changes.

## Firmware builds

Build using the Tailscale daemon already installed in the target's rootfs overlay:

```sh
export MIX_TARGET=ec100 # or x86_64
mix deps.get
mix firmware
```

The EC100 overlay has the checksum-verified official ARM daemon **1.104.1**.
Binaries are ignored by Git: on a clean checkout, place the official static daemon
for the target architecture at `rootfs_overlay/<target>/usr/sbin/tailscaled`, verify
its published SHA-256, and make it executable. Keep existing installations;
**firmware builds do not install or download Tailscale**. The dependency's optional
`mix tailscale.install` task still selects its older **1.102.3** test baseline, not
the latest release; it is not an update step for this overlay.

Firmware combines `rootfs_overlay/common` with `rootfs_overlay/<target>`. Keep the
ARM and x86 binaries separate. The device binary is `/usr/sbin/tailscaled`;
`rootfs_overlay/common/etc/iex.exs` prints `NervesMOTD` in serial or SSH IEx sessions.

Only an intentional daemon download needs internet on the **build host**. No software is downloaded on the device, and the Tailscale CLI is
not needed. Kernel TUN support is required to start in kernel mode; starting the
daemon does not enroll the device or enable LAN routing.

Nerves 2 requires a source timestamp. Target builds use the latest Git commit's
Unix timestamp, or `SOURCE_DATE_EPOCH` when supplied (required for source archives
without Git history). EC100 firmware assembly has been verified with OTP 29;
this is not an EC100 boot or Tailscale connectivity test.

The standard Nerves startup guard sends Heart's required initialization handshake
and validates firmware after all expected OTP applications start. It does not
require internet or completed setup. Keep the startup guard enabled while
`HEART_INIT_TIMEOUT` is set; VM heartbeat monitoring alone does not send that handshake.

## Networking and settings

`NervesGate.Network` owns Ethernet settings through VintageNet. Fresh gateways
try DHCP independently on both Ethernet ports, **without joining them**. Discovery
runs before USB is connected and updates the setup page as cables are plugged in.
A single verified Internet connection is suggested first; otherwise, a single
addressed local connection is suggested. Two equally plausible connections require
an explicit choice. VintageNet's Internet probes are bound to their own interface:
a cable or DHCP lease is not reported as verified Internet access.

`/setup` is one screen: use the detected Internet port, optionally add equipment,
then **Finish setup**. Manual Internet addressing is under **Change Internet
connection**, using the same button style as **Add equipment**. Equipment can wait,
and offline/USB-only setup is valid. After setup, use the editable `/settings` page;
`/setup` redirects there.

Switching to manual addressing fills in the selected interface's current address,
mask, router and DNS when available. Otherwise, example defaults are suggested:
Internet `192.168.1.2/24`, router/DNS `192.168.1.1`; equipment `192.168.10.2/24`.
Fallback suggestions avoid known other-port/USB subnets, but cannot guarantee an
unused address or discover equipment's static subnet. Check before saving and
reserve a DHCP address before reusing it manually. Existing drafts are preserved.

- **Separate ports**: assign at most one Internet port (DHCP or static IPv4) and
  optionally one equipment port (an unused static IPv4 address, no default route).
  Either role may be omitted. Unassigned ports are disabled after saving.
- **Explicit shared network**, under Advanced: both ports join `br0`, with DHCP or
  a static address and optional same-subnet router. Choose this only for one trusted
  network. STP is enabled; newly joined ports may take about 30 seconds to forward
  traffic. One missing port does not block the other.

Discovery never overwrites saved roles. Losing or moving a cable does not change
port assignments, bridge networks, or enable failover. Change roles in Settings.

Port 1/2 correspond to `eth0`/`eth1`. Static addresses support contiguous masks
(/1–/30); manual Internet/shared settings also accept up to three IPv4 DNS servers.
This software does not change equipment addresses, start an Ethernet
DHCP server, configure NAT, or enable equipment subnet forwarding. USB is never
part of a port-role change. Joining/splitting ports can interrupt Ethernet traffic.

Settings live in `/data/nerves_gate.json` (host: `tmp/dev/nerves_gate.json`). The
version-2 file is validated and written by fsync + atomic rename with mode 0600.
Version-1 files migrate **in memory** to the explicit shared arrangement, preserving
addresses and other settings; upgrading does not silently split an installed LAN.
The next explicit trial writes the migrated committed configuration before changing
interfaces. No credentials or observations are stored. Corrupt/unsupported files
are not overwritten.

First setup **through verified USB access** saves automatically after successful
application, without a countdown or second confirmation. Verification uses the
server-observed HTTP local address (signed into the LiveView session), the current
WebSocket peer, and USB's independent /30 subnet. Merely plugging in USB, supplying
form flags, or spoofing Host/forwarded headers does not qualify. Uncertain paths use
the protected flow. Automatic application has an internal 15-second deadline and
rolls back on failure; this is not a user confirmation timer.

First setup over Ethernet, and **all later network changes**, use a 60-second
undo window: choose **Keep changes** immediately when ready, or let previous
settings return. Later changes remain protected even over USB. Readiness means
interfaces have the intended configuration, topology and any manual addresses;
it does **not** require a cable, DHCP lease or Internet access. Observed overlaps
between Internet, equipment and USB subnets block saving; later DHCP overlaps
remain visible as warnings. Equipment or remote reachability is never inferred
from configuration readiness.

A GenServer, not the browser, owns application, saving and rollback. Only accepted
settings are on disk; restarting the manager or rebooting cancels pending changes.
Failed apply/save operations restore previous settings; rejected restore requests
are retried. VintageNet retries asynchronous interface failures. USB is always
independent and does not imply Internet sharing or remote equipment access.

## Shared device commands and projection (CQRS)

All client adapters use `NervesGate.Device`, including LiveView and the IEx/SSH
console. Ethernet and Tailscale commands share this boundary; cellular and firmware
actions are not exposed until their executors are implemented.

```elixir
alias NervesGate.Device

:ok = Device.subscribe()                 # subscribe before reading
view = Device.projection()
view.actions["network.propose"]          # enabled, reason, label, required parameters

settings = %{
  "mode" => "ports",
  "eth0" => %{"role" => "internet", "address" => NervesGate.Config.address_defaults()},
  "eth1" => nil # add equipment later, or assign a static equipment address
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
- `capabilities`: implemented features; Tailscale enrollment is available when its
  daemon is ready. Mobile and failover remain unavailable.
- `remote_access`: observed Tailscale state, name, addresses, daemon version,
  advertised routes, redacted health messages and the current async operation.
  Equipment reachability remains unverified; permitted routes are unknown (`nil`),
  not claimed empty. Private login URLs are never included.
- `actions`: stable string IDs with availability, a disabled reason (`code` and
  `message`), a display label and required string-keyed parameters.

Commands return `{:ok, %{result: result, projection: view}}` or
`{:error, %{error: %{code: code, message: message}, projection: view}}`.
`network.validate` only normalizes/checks a local draft; it does not save or apply
anything. The server revalidates every command. `expected_revision` is optional;
confirmation/cancellation always require the specific trial ID, never “whichever
trial is current”. Unsent form edits and countdown rendering stay local to each
client. A draft cannot overwrite settings saved by another session without a reload.
The legacy `ethernet` format remains readable; new separate-port saves use `ports`.
The trusted `:access` option is for server adapters only, never request parameters;
console/API commands without it always use confirmation.

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

`Device.Workflow` runs a pure Runic graph: network and remote policies feed the
projection and command-decision branches. `Device` serializes requests and executes
effect descriptions through `Network` or `Remote`. `Network` remains the safety
boundary for fresh readiness checks, durable saves, timeouts and retrying rollback,
even if the gateway/workflow crashes. `Remote` runs slow Tailscale writes in bounded
background tasks so login cannot block network rollback or UI status reads. A pristine
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
buttons, labeled fields, status indicators, notices and setting rows. Port and addressing choices use visible native radio cards rather than
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
MIX_TARGET=host mix run --no-start test/integration/tailscale.exs /absolute/path/to/tailscaled
```

The Tailscale compatibility check starts a private userspace daemon with temporary
identity storage and socket. It checks real cached status, rename, DNS settings and
preservation of existing preferences. It never attaches to the workstation daemon,
logs into an account, or changes kernel routing. Verified against daemon **1.104.1**;
this is not an enrolled-tailnet or hardware test.

The integration script requires Linux user namespaces, `ip`, `brctl`, `ifconfig`,
`udhcpc`, `dnsmasq`, `ping`, and `curl` in PATH. It never configures the workstation
LAN. It creates disposable LAN and USB peers and tests missing ports, hotplug,
bidirectional bridging, fresh DHCP discovery, first-USB automatic saving, static IP
changes, role transitions, port-role reversal and rollback. It fetches the real
setup page through the detected Ethernet address before USB exists, then Settings
through USB and both shared or separately addressed Ethernet ports.
Its DHCP server exists only in the simulated existing LAN, not in the gateway. This is **not** a Nerves boot or EC100
hardware test.

## Current scope

The offline UI provides Overview, Equipment, Internet & backup, Remote access,
and Settings. Initial setup and all clients share the device projection and command
API. Host mode is explicitly labeled simulation; use
`NervesGate.Network.Host.simulate/1` in IEx to change observations.

Equipment discovery, subnet routing/permissions, remote equipment verification,
cellular, failover and firmware upload remain unfinished. Saving local connections
or connecting Tailscale is **not** a claim that remote equipment access works.

## Tailscale

Open **Remote access** (`/remote`), enter a device name, and choose **Connect
Tailscale**. Follow the private sign-in link, then return to see connection or
machine-approval status. Once connected, the page shows the Tailscale address and
DNS name; you can save a new device name or explicitly disconnect. No auth key is
needed. Disconnecting interrupts a browser using that VPN; USB and LAN remain
available. These actions do not use Ethernet's 60-second rollback timer.

Tailscale's OTP application starts automatically on firmware, supervising
`/usr/sbin/tailscaled` in kernel mode. Identity/settings stay daemon-owned in
`/data/tailscale_ex`; the socket is under `/run`. Startup observes existing enrollment
without resetting it. Connect/rename disable Tailscale DNS management so VintageNet
keeps control, while preserving omitted preferences, existing routes and Serve
settings. Settings made before enrollment may be lost on daemon restart.

Gateway commands are `remote.connect` and `remote.configure` with
`%{"hostname" => "my-gateway"}`, plus `remote.disconnect` with no parameters.
Writes return `%{accepted: true}` immediately; observe `remote_access.operation`
and `remote_access.error` for completion. Do not blindly retry timed-out writes.
`remote.login_url` explicitly reads the private enrollment URL; keep it out of logs
and shared snapshots. The browser only displays HTTPS links to Tailscale's official
login hosts; URLs in daemon health text are redacted before broadcasting status.

Host preview simulates connect, rename and disconnect, and never starts or attaches
to the workstation's Tailscale daemon. Firmware login and account approval still
require testing on the device. This UI does not advertise equipment subnets, enable
forwarding, grant tailnet permissions, configure Serve/Funnel or verify reachability.
An advertised route is not proof of approval. Restrict access to port 4000 through
your Tailscale policy: the web UI remains unauthenticated.

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
