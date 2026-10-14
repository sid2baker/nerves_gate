# Networking and recovery

## Port roles

LAN 1 is `eth0`; LAN 2 is `eth1`. Numbers always identify the same physical ports, even when the dedicated Internet port is hidden from Equipment. On a fresh gateway, both independently try
DHCP. A single verified Internet port is suggested first; otherwise a single
linked, addressed port is suggested. Ambiguous connections require a choice.
Internet probes are interface-bound: a cable or DHCP lease is not proof of Internet.

Saved assignments never change automatically when a cable disappears or moves.
Use **Overview → Internet** to change them. Neither setup nor discovery bridges networks,
enables cellular backup or assigns an equipment address behind your back.

- **Separate ports:** at most one Internet port (DHCP or static IPv4), optionally
  one equipment port (static IPv4, no default route or DNS). Either may be omitted.
  Unassigned ports are disabled after saving.
- **Shared network**, under Advanced: both ports join `br0`, using DHCP or static
  addressing with an optional same-subnet router. Choose this only for one trusted
  network. STP is enabled; a newly joined port may take about 30 seconds to forward
  traffic. One missing port does not block the other.

Manual addressing supports contiguous IPv4 masks (/1–/30) and up to three DNS
servers for Internet/shared connections. Switching to manual fills the observed
address, mask, router and DNS when valid. Otherwise it suggests examples:
Internet `192.168.1.2/24` (router/DNS `192.168.1.1`), equipment `192.168.10.2/24`.
Suggestions avoid known other-port/USB subnets but cannot guarantee an unused
address or discover equipment's static subnet. Check before saving; reserve a DHCP
address before reusing it manually. Existing drafts are preserved.

Port configuration does not change equipment addresses, run an Ethernet DHCP
server or enable Internet sharing. VPN subnet access is a separate opt-in below. Joining/splitting ports interrupts
Ethernet traffic. USB is never part of these changes.

## Internet source and cellular preparation

**Overview → Internet** offers Ethernet, 4G modem, and Ethernet with 4G backup.
Existing saved settings remain Ethernet-only without migration. Cellular-only uses
separate ports with no Ethernet Internet assignment; a shared bridge can use
Ethernet or Ethernet with cellular backup. Equipment and USB are never modem bridges.

VintageNet owns Internet checks, route metrics, DNS and reconnection. Its normal
Internet-first routing prefers working Ethernet over working cellular, but working
cellular over Ethernet that only reaches its LAN. Our small metric callback also
classifies `br0` as Ethernet and a dedicated `cellN` modem as mobile. No failover
process, custom probes, Tailscale restart or route-writing loop is added. Failover
and failback follow VintageNet's connectivity detection, not Alarmist's debounce.
Existing sessions can briefly interrupt; seamless handover is not promised.

Backup is connected standby. Modem registration and connectivity checks can consume
mobile data even while Ethernet is preferred. There is no cold standby, data budget,
load balancing or custom failback hold timer.

The UI shows each permitted uplink and the preferred usable connection, not a
packet-level assertion about every flow. Internet loss alarms only when all permitted
uplinks are known unavailable. Using backup and an unavailable configured modem are
separate two-second Alarmist warnings. Unknown observations stay unknown; USB, VPN,
and unassigned Ethernet cannot make the Internet status healthy. USER1 can remain
solid on healthy cellular plus healthy Tailscale; USER2 indicates degraded redundancy.

### Modem qualification is still required

**The default EC100 firmware has cellular support disabled (`cellular: nil`).**
The local BSP has USB groundwork but no qualified modem power/reset or networking.
This repository prepares configuration, selection, persistence, UI and host tests;
it does not claim the unidentified factory modem works. No BSP changes are included.

Before enabling a modem, qualify inbound access protection for the unauthenticated
web UI as described under [HTTP exposure](#local-recovery-and-http-exposure).
Identify the module and its USB data/control interfaces first. Add only the matching
VintageNet technology dependency (with `runtime: Mix.target() != :host`) and required
BSP drivers. Configure power/reset and a stable, dedicated `wwanN`, `pppN` or `cellN`
identity. **Never give the modem `usb0`: that belongs to recovery and its DHCP server.**
Do not infer a modem's identity from enumeration order or send guessed GPIO/AT commands.

For an **identified and qualified QMI modem**, the firmware profile would be:

```elixir
config :nerves_gate, :cellular, %{
  interface: "wwan0",
  config: %{type: VintageNetQMI, vintage_net_qmi: %{}}
}
```

This is a profile example, not a promise the EC100 modem speaks QMI. The matching
package is not installed by default. A qualified PPP modem can instead supply a
standard `VintageNetMobile` configuration with its `:modem` implementation under
`:vintage_net_mobile`. ECM/MBIM support must be added after identifying the hardware;
there is no automatic protocol guessing. The UI reports unsupported hardware and
the Network domain rejects cellular proposals before changing Ethernet.

The application supplies one operator APN to that profile. The SIM must already be
unlocked; PIN attempts, username/password entry and roaming controls are not supported.
No SIM identifiers or credentials are exposed by the cellular status projection.

Modem configuration participates in the existing temporary trial and VintageNet
persistence. Source/APN metadata lives with `br0`'s existing topology metadata, not
in another settings file. Ethernet-only disables the qualified modem via VintageNet's
Null technology. Acceptance/readiness does not require a present modem, a SIM,
registration or Internet. Carrier registration can take longer than the undo window.
Confirmation saves interfaces individually; partial-save limitations below also apply
to cellular. Reboot restores saved configuration, never an unconfirmed trial.

Qualify real hardware with a working SIM: boot, modem removal, Ethernet cable loss,
Ethernet Internet loss with link still up, failback, both uplinks failing, reboot,
rollback, DNS, VPN traffic and blocked direct cellular HTTP access. The QEMU suite does not
qualify a cellular modem, carrier registration or modem power.

## Saving and rollback

VintageNet stores each LAN interface's settings using its FlatFile persistence
backend. The application keeps only the current trial in memory. QEMU integration
tests use the real persistence backend on a disposable disk. Unreadable saved settings fail closed.

The Ethernet modes remain `unconfigured`, `ports` and `shared`. An optional
`internet` object selects `ethernet`, `cellular`, or `backup`; cellular modes also
require `apn`. There is no legacy JSON importer or second persistence store.

First setup **through verified USB** saves automatically after successful
application. It has an internal 15-second deadline, not a user countdown. Verification
uses the server-observed HTTP local address (signed into the LiveView session),
the current WebSocket peer and USB's independent /30 subnet. Plugging in USB or
supplying form flags, Host or forwarded headers does not qualify. Uncertain access
paths use confirmation.

First setup over Ethernet, and **all subsequent network changes**, use a 60-second
undo window. Choose **Keep changes** when ready, **Restore previous settings**, or
let the timer restore them. Later changes stay protected even over USB.

Readiness means the intended configuration, topology and manual addresses are in
place. It does **not** require a cable, DHCP lease or Internet access. Observed
Internet/equipment/USB subnet overlaps block confirmation; later DHCP overlaps
remain visible as warnings. Configuration readiness does not imply equipment or
remote reachability.

### Temporary trials, subsystem-owned persistence

One Network GenServer admits and acknowledges commands using standard OTP calls and
replies. It checks first-USB-setup auto-save directly against current observations
and owns the independent watchdog and bounded hardware worker.

1. **Propose:** apply temporarily without changing saved settings. Acknowledge
   after application; immediately-ready first USB setup waits for auto-save.
2. **Confirm:** recheck the exact trial ID, monotonic deadline, readiness and
   conflicts, then save each LAN interface through VintageNet's persistence API.
3. **Cancel, timeout or failed apply:** stop and join the worker,
   then restore the prior applied configuration. USB remains untouched.
4. **Server restart/reboot:** load and apply VintageNet's saved settings, not a
   pending trial or a resumed countdown. Failed restoration retries with new
   proposals blocked.

**There is no multi-interface transaction.** Interrupted or failed confirmation
can leave some interfaces saved and others unchanged. Runtime rollback does not
undo those disk writes; the next restart uses the settings VintageNet has. This
is an accepted tradeoff, not a promise of all-or-nothing power-loss recovery.
There is no trial journal, commit marker or custom application file-writing layer.
Keep USB/serial recovery available.

VintageNet owns interface state, hotplug, cleanup and asynchronous retries. An
admitted operation can outlive its caller, so the adapter retains a bounded
configuration/bridge-membership settlement barrier. Rollback does not depend on
the browser, Alarmist or successful notification delivery. Failed restoration raises
an Alarmist fault; successful restoration clears it. The alarm does not drive recovery.

## Tailscale

In **Overview → Remote access**, enter a device name, select **Connect Tailscale**, then
follow the private sign-in link. Return to see connection or machine-approval
status. No auth key is needed. The same page shows gateway addresses, rename and
disconnect. The equipment LAN page has the on/off control for its IPv4 subnet. Disconnect uses `Tailscale.down/0`, preserving enrollment and preferences.
Reconnect uses `up/0` for an enrolled profile, or login when enrollment is needed.
Disconnecting may interrupt a browser using that VPN. USB and LAN remain available. These operations do not use Ethernet's
rollback timer.

Remote is one GenServer admitting one bounded, linked daemon worker at a time.
Acceptance does not mean completion. Crashes or timeouts stop the worker;
startup only observes
the daemon, never replays a connect/rename/disconnect. Daemon-side work may still have
completed, so read status before retrying.

The Tailscale OTP application supervises `/usr/sbin/tailscaled` in kernel mode.
Kernel TUN support is required. Identity and settings stay daemon-owned in
`/data/tailscale_ex`; the socket is `/run/tailscale/tailscaled.sock`. Starting the
daemon does not enroll it or add equipment routes. Existing daemon preferences,
including advertisements and running intent, still apply at startup. Firmware builds
preserve existing enrollment rather than resetting preferences.

Connect/rename set `accept_dns: false` so VintageNet retains DNS ownership, while
preserving omitted preferences, routes and Serve settings. Startup observes an
existing profile without rewriting it. If a profile enrolled outside this UI has
Tailscale DNS enabled, disable only that setting from recovery IEx:

```elixir
Tailscale.update_configuration(%{accept_dns: false})
```

Do not reset all preferences to fix DNS. Tailscale cannot manage `/etc/resolv.conf`
on the read-only rootfs. Settings made before enrollment may not survive a daemon
restart; the library's default configuration is not an automatic startup policy.

Daemon health URLs are redacted before publishing status. Private enrollment URLs
are explicit reads and the UI accepts only HTTPS links to official Tailscale login
hosts. The UI does not grant tailnet permissions, configure Serve/Funnel or verify
equipment reachability.

### Equipment sharing

Turn **Share equipment network** on to advertise the confirmed dedicated equipment
IPv4 subnet, for example `192.168.50.0/24`. Use equipment's normal addresses, such as
`192.168.50.10`. There are no site IDs, alternate addresses or route-entry fields.
Enable requires the confirmed address, link and topology. Shared LAN and USB are
not eligible. Approve the route in Tailscale, restrict access in tailnet policy and
test the intended service separately. Linux clients must enable accepting subnet
routes (`tailscale set --accept-routes`); other supported clients normally accept them.
This is routed access, not an Ethernet bridge or broadcast-discovery service.

**Overlapping networks are unsupported.** Equipment subnets must not overlap other
sites, the client's LAN or another VPN's routes. The gateway checks its observed
local conflicts but cannot inspect every client's routing table. Use distinct
subnets or disconnect the conflicting VPN; there is no translation workaround.

On merges that one subnet into the current advertisement list; Off removes only
that subnet, even if the link or VPN is offline. Other routes, preferences, Serve
settings and enrollment are preserved. These actions never change running intent.
Do not edit route preferences concurrently through another LocalAPI client:
read/merge/write is serialized within this application, not across clients.

Route operations hold the existing LAN worker. Any advertised route (including
external advertisements) or unknown outcome blocks LAN proposals; we do not guess
which external routes depend on the LAN. Independent rollback and USB recovery
remain available. A timed-out mutation may still complete: explicitly turn sharing
off and wait for readback. An empty cached route list does not clear uncertainty.
Restart reads preferences without replaying writes.

At firmware application startup, `Network.Vintage.prepare_routing/0` sets the IPv4
FORWARD policy to DROP before enabling `net.ipv4.ip_forward`, preventing unrestricted
Ethernet/USB forwarding. It uses a direct `System.cmd/3` call and `File.write/2`;
there is no shell script, boot marker or extra process. Tailscale's native netfilter
rules and default subnet SNAT provide VPN forwarding. A setup failure logs a warning
without preventing the web UI or local recovery from starting. Host builds do nothing.
This does not change INPUT/OUTPUT policy or enable IPv6 forwarding.

Tailscale uses the gateway's routing table, not an equipment-interface pin. Removing
an advertisement or disconnecting is not proof that existing sessions have ended.
The UI reports advertisements, not isolation, approval or reachability. Authenticated
end-to-end routing, NAT and real-device behavior still require target qualification.

#### Existing external or legacy routes

Old 4via6 advertisements are not converted or deleted automatically. They remain
external Tailscale preferences and may still provide access. The equipment switch
only controls the current IPv4 subnet; other advertisements must be removed before
LAN changes. Inspect them under **Overview → Remote access → Connection details**.
From recovery IEx, remove only the exact unwanted route, preserving the others:

```elixir
routes = Tailscale.get_configuration().advertise_routes
# Replace this string with the exact old route you intend to withdraw.
Tailscale.update_configuration(%{advertise_routes: List.delete(routes, "old-route/CIDR")})
```

Do not reset all daemon preferences or delete routes belonging to other services.

## Erlang distribution and Livebook

Firmware starts standard OTP distribution when the existing Tailscale observations
report an online IPv4 address. The node is named `nerves_gate@<Tailscale-IPv4>`, for
example `nerves_gate@100.88.166.70`. Neither the tailnet nor node name needs to be
known at build time; MagicDNS is not required. Before enrollment/connection, distribution
waits without blocking startup, HTTP or recovery. Normal host preview/tests never
start distribution.

The existing Remote status updates call `Node.start/2` once the address is known.
OTP owns the distribution processes and EPMD; there is no extra watcher, manager or
clustering dependency. Temporary VPN outages leave the node running. Re-enrolling
with a different IPv4 address restarts distribution under the new name, disconnecting
attached clients; read the page again and reconnect. A Tailscale hostname rename
does not affect the node name.

Firmware listens on TCP **4369** (EPMD) and **9100** (distribution), on all IPv4 interfaces. Restrict both ports in your tailnet/network policy. There are no new
INPUT rules. Native distribution is unencrypted; Tailscale supplies encryption on
the VPN path. Do not expose these ports or the unauthenticated UI to the Internet.

**Overview → Erlang distribution** shows the running node name and cookie.
The existing trusted-network model applies: anyone who can read the page and reach
these ports can execute arbitrary code on the gateway. The cookie authenticates
VM access, even when used operationally as a shared group value. It is not included
in the general `NervesGate.status()` projection or observation broadcasts.

OTP creates/reuses `$HOME/.erlang.cookie` (normally `/root/.erlang.cookie`, on the
persistent data partition). It survives reboot and in-place firmware updates; factory
reset erases it. Production does not bake in a cookie. `MIX_ENV=dev` builds instead
use the public `:mycookie` without changing that file; use only trusted development
networks. To give several production nodes the same
cookie, provision that standard file with identical contents and owner-only permissions,
then reboot. Changing a running node's cookie with `Node.set_cookie/1` alone does not
persist it or disconnect existing peers. Matching cookies do not discover nodes;
connect explicitly with `Node.connect(:"nerves_gate@100.64.0.2")`.

Run Livebook on your computer/server, not on the gateway. Choose **Attached node**
and copy the node name and cookie from the page. Livebook must use the same Elixir
minor version shown there and a compatible OTP version (currently Elixir 1.20 / OTP 29).
An attached runtime cannot install dependencies: add S7, EtherCAT or other libraries
to firmware when needed. Permanent equipment sessions belong under the gateway's
supervision tree, not the notebook evaluator. SSH/serial IEx remains the recovery path.

## Observations

LiveViews subscribe to existing VintageNet/Tailscale properties and application
workflow metadata, then reread status. There is no central snapshot server or
second PubSub lifecycle feed. Private login URLs are excluded. Pending network
trials reconcile current readiness periodically if a notification was missed.

Internet status comes from the permitted interfaces' VintageNet observations.
Unconfigured or equipment-only networking does not require Internet. There is no
separate connectivity retry agent, automatic role reassignment, DHCP restart, VPN
reconnect, enrollment or DNS reset. Explicit cellular backup uses VintageNet routing.

## Local recovery and HTTP exposure

Firmware binds **all IPv4 interfaces, port 4000**. The UI is unauthenticated:
anyone who can reach it can change settings. Do not expose it to a public cellular
network. Restrict inbound access as part of modem/deployment qualification before
enabling cellular; this application does not install cellular INPUT rules.

The listener starts normally without USB, cellular support or a boot marker, and
accepts connections on interfaces added later. This does not configure an address
or enroll a VPN. Host preview listens only on `127.0.0.1`.

For USB recovery, open `http://<gateway-usb-address>:4000/network`. VintageNetDirect
derives the USB /30 subnet at runtime; there is no fixed device IP. From serial or
SSH IEx, inspect:

```elixir
VintageNet.get(["interface", "usb0", "addresses"])
```

USB's small DHCP server is confined to USB. It does not share your laptop's Internet
connection. The kernel must expose `usb0`; application configuration cannot create
missing USB gadget hardware. The EC100 system includes the fixed-role USB
restoration; x86 does not assume a USB gadget exists.

Keep a local recovery path when changing Ethernet or updating firmware. SSH is
key-only, with build-time `NERVES_GATE_SSH_KEYS`; the HTTP listener's policy does not
change SSH exposure. USB, serial and real cable/hotplug behavior require hardware
verification, not only tests with hardware fakes.

## Logs across reboots

Firmware uses RingLogger's built-in persistence: the last 1024 entries are saved
to `/data/ring_logger.log` every five seconds and loaded again at startup. After
reboot, use `RingLogger.tail(1024)` from SSH/serial IEx. Collect promptly, before
new messages replace the incident. The persistence file is binary, not plain text;
`RingLogger.save("/data/incident.txt")` exports the current buffer as text.

This is best-effort debugging, not a crash-proof journal: snapshots are not atomic
or explicitly synced, so a hard freeze/power cut can lose recent messages or the
snapshot. Keep UART capture too. Frequent snapshots add flash writes; increase
`persist_seconds` after the investigation. Treat logs as private diagnostics.
Factory reset stops the logger before unmounting data and erases the saved logs.
Host development does not enable persistence.

## Known runtime limitation

With host OTP 29.1, MuonTrap can intermittently exit with `:epipe` when a short-lived
command finishes. This was reproduced independently of networking (55 of 2,000
`printf` commands) and during isolated network integration runs. VintageNet
retries interface failures; a failed network trial is rejected and recovery is
attempted, not reported as saved. A crashed interface can also delay recovery.
A passing integration run does not eliminate this upstream command-runner race.
The repository does not monkey-patch
MuonTrap or suppress the failure. See [architecture](architecture.md) for the
remaining dependency and verification limitations.
