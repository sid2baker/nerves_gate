# Networking and recovery

## Port roles

LAN 1 is `eth0`; LAN 2 is `eth1`, even when Equipment hides the Internet port. On
a fresh gateway both try DHCP. A single verified Internet port is suggested first,
otherwise a single linked, addressed port; ambiguous connections require a choice.
Internet probes are interface-bound: a cable or DHCP lease is not proof of Internet.

Saved assignments never change when a cable disappears or moves. Use
**Overview → Internet** for the uplink and **Equipment → LAN 1 / LAN 2** for
equipment addressing. Each editor preserves the other's settings, and a port used
for Internet cannot be reassigned from Equipment. Nothing bridges networks, enables
cellular backup or assigns an equipment address automatically.

- **Separate ports:** at most one Internet port (DHCP or static IPv4) and optionally
  one equipment port (static IPv4, no default route or DNS). Unassigned ports are
  disabled after saving.
- **Shared network** (Advanced): both ports join `br0` with DHCP or static
  addressing and an optional same-subnet router. Use it only for one trusted
  network. STP is enabled, so a newly joined port may take about 30 seconds to
  forward. One missing port does not block the other.

Manual addressing supports contiguous IPv4 masks (/1–/30) and up to three DNS
servers for Internet/shared connections. Switching to manual fills in the observed
address, mask, router and DNS when valid, otherwise examples (Internet
`192.168.1.2/24` via `192.168.1.1`, equipment `192.168.10.2/24`). Suggestions avoid
known other-port and USB subnets but cannot guarantee an unused address; check
before saving.

Port configuration never changes equipment addresses, runs an Ethernet DHCP server
or shares Internet. Joining or splitting ports interrupts Ethernet traffic. USB is
never part of these changes.

## Internet source and cellular

**Overview → Internet** offers Ethernet, 4G, or Ethernet with 4G backup; settings
without a source are Ethernet-only. 4G-only needs separate ports; a joined bridge
can use Ethernet or Ethernet with backup. Equipment and USB never bridge to the modem.

VintageNet owns connectivity checks, route metrics, DNS and failover: working
Ethernet beats working cellular, which beats Ethernet that only reaches its LAN.
Backup is connected standby, so the modem stays registered and can use mobile
data. There is no cold standby, data budget, load balancing or failback timer.
Internet loss alarms only when every permitted uplink is known unavailable; using
backup and an unavailable modem raise separate warnings.

### Cellular modem

EC100 firmware supports the built-in Quectel EG800AK-GL. The system powers it and
names its CDC-ECM data interface `wwan0`; `VintageNetECM` drives it over
`ttyUSB2` and gets IPv4 by DHCP. The modem's factory USB mode must stay ECM;
firmware never changes it, and **never give the modem `usb0`**, the recovery link.

```elixir
config :nerves_gate, :cellular, %{
  interface: "wwan0",
  config: %{type: VintageNetECM, vintage_net_ecm: %{at_tty: "ttyUSB2"}}
}
```

QEMU has no modem (`cellular: nil`). 4G choices stay disabled until a modem is
actually detected, and the backend rejects enabling cellular or changing its APN
without one; other edits keep existing cellular settings. Inbound cellular traffic
is [filtered](#local-recovery-and-http-exposure) before networking starts.

Cellular uses the network's default APN (an empty APN) unless you set
**Advanced cellular settings → APN override**. Not every operator provides a
default; business and IoT SIMs often need a specific APN. APN usernames and
passwords are unsupported. Modem settings use the normal trial and rollback.

Modem identity and AT/ECM commands are verified on hardware. Registration, DHCP,
failover and PIN handling with a working SIM are not yet validated.

### SIM commissioning and saved PIN

Once cellular is enabled, the Internet page shows SIM state, PIN protection,
remaining attempts, registration, operator and signal. Unknown is not proof of a
missing SIM, and Refresh is read-only. PIN entry is accepted only in the device's
own UI over verified direct USB, or through the administrative
[Elixir API](action-api.md). All SIM commands share Network's single worker, and
VintageNetECM remains the only AT-port user.

- **Unlock and save PIN** sends one 4–8 digit PIN. After success and a fresh
  READY/identity check, the PIN is saved bound to a hash of the SIM's ICCID.
- **Verify and save PIN** checks the PIN of an already-ready SIM by reapplying its
  current protection setting once. **A wrong PIN consumes an attempt.**
- **Advanced** changes the PIN or turns protection on or off, once. Success saves
  the verified PIN; disabling protection forgets it. After an unknown PIN-change
  outcome, never try both codes blindly.
- **Forget saved PIN** deletes the record without touching the SIM.

PUK, PIN2, SMS and USSD are unsupported; recover a blocked SIM with the carrier or
a phone. SIM operations are not network trials and rollback does not undo them.

After a restart, the saved PIN is sent automatically only when the SIM asks for it
and its fresh identity matches. The record is blocked *before* that single attempt
and re-armed only by a known success, so a failed or uncertain attempt stays
blocked across reboots and no PIN is ever retried blindly. If the modem cannot
report the ICCID while locked, nothing is sent and manual unlock is required.

The record is `/data/nerves_gate/cellular/pin.json` (owner-only). It is **not
encrypted**: root access, full eMMC backups and VM crash dumps can expose it.
Status, projections, notifications and logs never contain the PIN or SIM identity.
Factory reset erases it.

## Saving and rollback

Internet, equipment and LAN arrangement have separate UI drafts but one Network
owner and one configuration. All pages show the same active trial and timer. Saving
checks the draft's original configuration inside Network; stale drafts are rejected
and must be reloaded.

**Settings → LAN ports** selects Separate or Joined and the joined network's
address. Joining replaces both port assignments; separating leaves both ports
unassigned. The Internet source and APN must stay valid for the arrangement
(4G-only cannot use joined ports; 4G backup needs an Ethernet uplink).

VintageNet stores interface settings; the trial exists only in memory. Unreadable
saved settings fail closed. See the [public API](action-api.md) for the format.

First setup **through verified USB** saves automatically after successful
application, within an internal 15-second deadline. Verification uses the
server-observed HTTP local address (signed into the LiveView session), the current
WebSocket peer and USB's independent /30 subnet. Plugging in USB, form flags, Host
or forwarded headers do not qualify; uncertain paths use confirmation.

Every other change, including first setup over Ethernet, has a 60-second window:
**Keep changes**, **Restore previous settings**, or let the timer restore them.

Readiness means the intended configuration, topology and manual addresses are in
place; it needs no cable, DHCP lease or Internet. Observed Internet/equipment/USB
subnet overlaps block confirmation; later DHCP overlaps are shown as warnings.

Cancellation, expiry or failed application restores the previous configuration.
Rollback is device-owned and continues if the browser disconnects. Restart loads
saved settings, never an unconfirmed trial. Failed restoration raises an alarm and
retries with new proposals blocked.

**Saving several interfaces is not a transaction.** An interrupted confirmation can
save some interfaces but not others, and rollback cannot undo those writes. Keep
USB or serial recovery available.

## Tailscale

**Overview → Remote access** shows connection details above the settings. Enter a
device name, choose **Sign-in link** or **Auth key**, then **Connect Tailscale**.
Browser enrollment opens a private popup with the sign-in URL in the requesting view
only; it can be closed and reopened without reconnecting. Auth keys are masked,
cleared after each submission, never saved or shown in status, and filtered from
request logs. Key login waits for authentication or machine approval within the
operation deadline.

The same page renames and disconnects. Disconnect uses `Tailscaled.down/0`, keeping
enrollment and preferences; reconnect uses `up/0`, or login when enrollment is
needed. Disconnecting can cut off a browser using the VPN; USB and LAN remain.
These operations have no rollback timer.

One remote operation runs at a time. A timed-out operation may still complete, so
read status before retrying. Restarts never replay commands.

The `tailscaled_ex` application supervises `/usr/sbin/tailscaled` in kernel mode
(TUN required). State lives in `/data/tailscaled_ex`; the socket is
`/run/tailscale/tailscaled.sock`. Starting the daemon neither enrolls it nor adds
routes, but existing preferences, advertisements and running intent apply. Firmware
updates keep enrollment.

Connect and rename set `accept_dns: false` so VintageNet keeps DNS ownership, and
preserve other preferences and routes. If a profile enrolled elsewhere has Tailscale
DNS enabled, disable only that from recovery IEx:

```elixir
Tailscaled.update_configuration(%{accept_dns: false})
```

Do not reset all preferences: Tailscale cannot manage `/etc/resolv.conf` on the
read-only rootfs.

Daemon health URLs and key tokens are redacted from status. Private enrollment URLs
are explicit reads, and the UI accepts only HTTPS links to official Tailscale login
hosts. The UI does not grant tailnet permissions or verify equipment reachability.

### Gateway HTTPS

With MagicDNS and HTTPS enabled in the tailnet, an enrolled, online gateway
configures **HTTPS 443 → `http://127.0.0.1:4000`**. Open `https://<gateway-dns-name>/`
from an authorized tailnet device. There is no port 80 listener or Funnel. LAN/USB
access on port 4000 is unchanged.

The remote worker applies Serve once per observed DNS name, at startup and after
rename. Failures are reported in remote status without automatic retries; reconnect
or save the unchanged name to retry. Readback does not prove certificate issuance
or browser access.

The gateway owns the daemon's top-level Serve listeners: it replaces custom
listeners and clears Funnel, preserving other preferences, routes and Tailscale
Services.

LiveView uses Phoenix's session-bound CSRF validation instead of WebSocket Origin
checks, so dynamic LAN/USB/tailnet hosts and HTTPS termination work without proxy
headers. HTTP CSRF protection and Strict session cookies stay enabled. Forwarded
headers are not trusted. HTTPS adds no sign-in; restrict tailnet access.

### Equipment sharing

**Share equipment network** advertises the confirmed dedicated equipment IPv4
subnet, for example `192.168.50.0/24`; reach equipment at its normal addresses.
It requires the confirmed address, link and topology; shared LAN and USB are not
eligible. Approve the route in Tailscale and restrict it in tailnet policy. Linux
clients need `tailscale set --accept-routes`. This is routed access, not an
Ethernet bridge or broadcast discovery.

**Overlapping networks are unsupported.** Equipment subnets must not overlap other
sites, the client's LAN or another VPN's routes. The gateway checks only its own
observed conflicts.

On merges the subnet into the advertisement list; Off removes only that subnet,
even offline. Other routes, preferences, Serve settings, enrollment and running
intent are preserved. Read/merge/write is serialized only within this application,
so do not edit routes concurrently through another LocalAPI client.

Route operations hold Network's guard. Any advertised route, including external
ones, or an unknown outcome blocks LAN proposals. After a timed-out change, turn
sharing off explicitly and wait for readback. Restart reads preferences without
replaying writes. Other advertisements are listed under **Connection details**.

At startup, `Network.Vintage.prepare_routing/0` sets the IPv4 FORWARD policy to
DROP before enabling `net.ipv4.ip_forward`; Tailscale's netfilter rules and subnet
SNAT provide VPN forwarding. A failure logs a warning without blocking the UI or
recovery. INPUT/OUTPUT policy and IPv6 forwarding are unchanged; host builds do
nothing. Removing an advertisement does not end existing sessions.

## Erlang distribution and Livebook

Once Tailscale reports an online IPv4 address, firmware starts OTP distribution as
`nerves_gate@<Tailscale-IPv4>`, for example `nerves_gate@100.88.166.70`. Until then
it waits without blocking startup, HTTP or recovery. VPN outages leave the node
running. A new address restarts distribution under the new name and disconnects
clients; renaming the host does not. Development launchers start distribution
themselves; QEMU uses its management network (see
[the simulator](development.md#workbench-and-simulator)).

Firmware listens on TCP **4369** (EPMD) and **9100** (distribution) on all IPv4
interfaces. Native distribution is unencrypted; Tailscale encrypts the VPN path.
Restrict both ports in tailnet and network policy, and never expose them publicly.

**Overview → Erlang distribution** shows the node name and cookie. Anyone who can
read the page and reach these ports can run arbitrary code on the gateway. The
cookie is not in `NervesGate.status()` or broadcasts.

OTP creates `$HOME/.erlang.cookie` (normally `/root/.erlang.cookie`) on the data
partition: it survives reboots and updates, and factory reset erases it. `MIX_ENV=dev`
builds use the public `:mycookie` instead; use them only on trusted development
networks. To share a cookie across production nodes, provision that file with
identical contents and owner-only permissions, then reboot. Connect nodes
explicitly with `Node.connect(:"nerves_gate@100.64.0.2")`.

Run Livebook on another computer as an **Attached node** with the shown name and
cookie, using the same Elixir minor and a compatible OTP (Elixir 1.20 / OTP 29).
Attached runtimes cannot install dependencies, so add libraries to firmware.
Permanent equipment sessions belong in the gateway's supervision tree, not a notebook.

## Observations

Internet status comes only from permitted interfaces, never USB or the global best
connection. Unconfigured or equipment-only networking does not require Internet.
Unknown observations are not healthy, and Tailscale Running does not prove Internet.

The [UI projection](architecture.md#ui-projection) only distributes sanitized
observations. Roles never change automatically, and alarms do not restart DHCP or
VPN or reset DNS.

## Local recovery and HTTP exposure

Firmware serves the UI on **all IPv4 interfaces, port 4000**, without sign-in:
anyone who can reach it can change settings and add SSH keys. Keep it on trusted
networks. Before VintageNet restores saved connections, firmware installs IPv4
and IPv6 INPUT rules on `wwan+`: accept established/related replies, allow IPv4
DHCP server replies (UDP 67 → 68), and drop everything else. Rules are placed
before existing INPUT rules and installation is idempotent. Installation failure
stops firmware startup; it never continues with an unprotected cellular link.
Cellular data calls use IPv4; new IPv6 traffic is also denied. These rules do not
restrict USB, Ethernet or Tailscale interfaces. The listener accepts interfaces
added later. Workstation UIs listen only on `127.0.0.1`.

For USB recovery, open `http://<gateway-usb-address>:4000/network`. VintageNetDirect
derives the USB /30 subnet at runtime; there is no fixed address. From serial or
SSH IEx:

```elixir
VintageNet.get(["interface", "usb0", "addresses"])
```

USB's DHCP server is confined to USB and does not share the laptop's Internet. The
kernel must expose `usb0`: the EC100 system sets up its fixed-role USB gadget; x86
does not assume one.

Connect with `ssh root@<gateway-usb-address>` and password `nerves_gate`. Password
login checks the actual TCP peer against the live `usb0` /30, link state and direct
return route, and fails closed on overlaps, gateways, VPN route overrides or
uncertainty. Ethernet, Tailscale, IPv6 and QEMU management need keys.

Manage SSH public keys under **Settings**. Keys grant full access, including IEx,
SFTP and firmware uploads. Changes are saved to
`/data/nerves_gate/ssh_authorized_keys` before taking effect. Build-time
`NERVES_GATE_SSH_KEYS` and configured NervesSSH keys seed the store only on first
use or after factory reset. Use `NervesGate.ssh_add_key/1` and `ssh_remove_key/1`,
not NervesSSH's key APIs.

## Logs across reboots

Firmware saves the last 1024 RingLogger entries to `/data/ring_logger.log` every
five seconds and reloads them at startup. After a reboot, use `RingLogger.tail(1024)`
from IEx promptly, before new messages replace them, or export text with
`RingLogger.save("/data/incident.txt")`.

Snapshots are best effort, not atomic or synced: a freeze or power cut can lose
recent messages. Keep UART capture too, and treat logs as private. Factory reset
erases them. Host development does not persist logs.

## Known runtime limitation

With OTP 29.1, MuonTrap can intermittently exit with `:epipe` when a short-lived
command finishes. VintageNet retries interface failures; an affected network trial
is rejected and restored, never reported as saved, though recovery can be delayed.
The repository does not patch MuonTrap or hide the failure.
