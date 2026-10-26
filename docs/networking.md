# Networking and recovery

## Port roles

LAN 1 is `eth0`; LAN 2 is `eth1`. Hardware shows both, including the Internet uplink. On
a fresh gateway both try DHCP. A single verified Internet port is suggested first,
otherwise a single linked, addressed port; ambiguous connections require a choice.
Internet probes are interface-bound: a cable or DHCP lease is not proof of Internet.

Saved assignments never change when a cable disappears or moves. Use
**Overview → Internet** for the uplink and **Hardware → LAN 1 / LAN 2** to enable
or disable application access on independent, non-Internet ports. Enabling assigns
no IPv4 address and starts no DHCP client, DNS, default route, bridge or advertisement.
Disabling holds the independent link down. Existing local addresses are removed only
by an explicitly saved change. Legacy equipment/joined configurations are rejected
with migration guidance, never automatically converted or erased. Internet cannot take an
enabled application port until application access is disabled.

Applications request local addressing with `NervesGateSDK.Network.claim_local/3`.
The actual caller owns one isolated link; a claim never changes Internet/USB or
persists its IP configuration. The first implementation admits one claim per gateway.
Use the optional [Tailnet subnet-router app](../apps/tailnet_subrouter/README.md)
for explicit configuration and route advertisement. Unresolved claims block network
changes until safe cleanup; no app is enabled by visiting Hardware.

The administrative API accepts independent ports only: at most one Internet port
(DHCP or static IPv4), application-enabled ports without saved addresses, and
disabled ports. Hardware has no local-addressing or topology editor. Saved legacy
`equipment` roles or `shared` mode make Network unavailable with migration guidance;
they are never rewritten. VintageNet/daemon state may survive independently: inspect
it using recovery SSH before a separately authorized migration. Keep USB available.

Manual Internet addressing supports contiguous IPv4 masks (/1–/30) and up to three
DNS servers. Suggestions use observed addressing or `192.168.1.2/24` via
`192.168.1.1`, avoiding known other-port/USB subnets. They cannot prove an address
is unused. Application addresses are requested transiently through leases, never
saved as a second gateway-owned local network. No Ethernet DHCP server or Internet
sharing is provided; USB is never part of Ethernet changes.

## Internet source and cellular

**Overview → Internet** offers Ethernet, 4G, or Ethernet with 4G backup; settings
without a source are Ethernet-only. 4G-only has no Ethernet Internet assignment;
backup requires one. Other Ethernet interfaces may be enabled for applications,
but only one application lease is admitted per gateway. Ethernet and USB never
bridge to the modem, and application leases create no default routes or DNS.

VintageNet owns connectivity checks, route metrics, DNS and failover: working
Ethernet beats working cellular, which beats Ethernet that only reaches its LAN.
Backup is connected standby, so the modem stays registered and can use mobile
data. There is no cold standby, data budget, load balancing or failback timer.
Internet loss alarms only when every permitted uplink is known unavailable; using
backup and an unavailable modem raise separate warnings.

Choose LAN, 4G or LAN with 4G backup. LAN defaults to DHCP; 4G uses automatic carrier
settings. If the SIM asks for a PIN, **Unlock and connect** sends it once and
remembers it only after verification. The current LAN source stays unchanged
until that exact unlock request succeeds. Only that explicit Connect intent can
continue into the network trial; a refresh, reconnect or unrelated client's PIN
operation cannot apply a draft. Leaving the flow cancels continuation, not an
already-accepted SIM operation. Internet access is not required to confirm or
finish setup; existing trial/rollback protection remains.

Configured gateways show a compact live summary with **Change setup** and a
**Connection settings** link to `/network/details`. There are no expanders. The
settings page shows carrier/plan selection, manual addressing and diagnostics as
ordinary fields. Only **Other / private APN** shows manual APN/PAP inputs. SIM
observations refresh automatically up to every 30 seconds without overwriting
drafts. Configured/carrier-profile APNs are not proof of Internet; the summary uses
interface-bound connectivity observations. Backup preference follows configured
priority and connectivity, not measured traffic.

### Cellular modem

EC100 firmware supports the built-in Quectel EG800AK-GL. The system powers it and
names its CDC-ECM data interface `wwan0`; `VintageNetECM` drives it over
`ttyUSB2` and gets IPv4 by DHCP. The modem's factory USB mode must stay ECM;
firmware never changes it, and **never give the modem `usb0`**, the recovery link.

The EC100 board's `:cellular` profile is:

```elixir
%{
  interface: "wwan0",
  sim_detect_level: 1,
  config: %{
    type: VintageNetECM,
    vintage_net_ecm: %{at_tty: "ttyUSB2", modem: NervesGate.Cellular.Modem}
  }
}
```

`Cellular.Profile` owns board/config generation; `Cellular.SIM` owns SIM/PIN
lifecycle and `Cellular.Authentication` owns private APN-bound PAP.
`Cellular.Modem` implements the VintageNetECM modem contract and bounded UART
commands. Public `Cellular` operations share Network's single worker: there is no
separate Cellular GenServer or second UART owner.

Before VintageNet restores saved connections, startup checks the saved cellular
configuration and its modem callback module. An unavailable/incompatible saved
driver fails startup visibly, before opening the UART; it is not aliased, silently
migrated or erased. Deployments with incompatible saved settings need a separately
authorized reprovision/reset procedure. A build alone is not permission to erase
network settings, app data or credentials.

The qualified EC100 driver keeps its existing AT controller available for SIM
setup even while the Internet source is LAN. This control-only configuration has
IPv4 disabled and activates no packet data connection. It never creates a second
UART owner or changes LAN/USB addressing. SIM unlock, observation and credential
storage are available before enabling cellular data; automatic PIN unlock and
reconnection require an enabled cellular source.

SIM detection is checked once per ECM controller lifetime through that
controller's existing AT port. EC100 uses active-high
hot-plug detection (`AT+QSIMDET=1,1`). If the setting differs, setup changes it and
reinitializes the modem's SIM/radio function once; an already-correct setting
causes no reset. If the initial read cannot yet reach the starting controller,
it is retried after a five-second backoff. Once any setup write was attempted,
failed/uncertain setup is reported rather than replayed on refresh. No PIN is sent
by this setup.

QEMU has no modem (`cellular: nil`). 4G choices stay disabled until a modem is
actually detected, and the backend rejects enabling cellular or changing its APN
without one; other edits keep existing cellular settings. Inbound cellular traffic
is [filtered](#local-recovery-and-http-exposure) before networking starts.

### Automatic carrier setup

Like a phone, firmware carries an offline carrier database: the public-domain
GNOME `mobile-broadband-provider-info` Internet profiles. After unlocking, the
modem domain reads the SIM's home network, service-provider name and MNC length.
Raw IMSI/SIM files never enter status or logs. Exact SIM-brand matches distinguish
virtual operators sharing a network. Automatic selection requires unambiguous,
supported settings; otherwise it tries the network default without inventing
credentials. This is not a guarantee for every SIM, roaming plan or private APN.

If automatic setup does not connect, **Connection settings → Carrier / plan**
offers compatible carrier names. Presets include public default PAP credentials;
the UI never asks users to look these up or exposes them. A stable public profile
ID is saved with an explicit choice because brands can share an APN but require
different authentication. The driver rechecks that choice against the inserted
SIM. Only an unlisted/private plan needs an APN from its carrier. Choosing a
carrier or changing the APN uses normal trial/rollback; private credentials remain
separate. CHAP-only presets and IPv6 are not supported.

The bundled data records its upstream commit and license in `priv/cellular/`.
Update it explicitly with `mix run --no-start scripts/update_cellular_providers.exs
<upstream-commit>` at the repository root, then rebuild firmware. Runtime setup
needs no Internet lookup or carrier service.

#### PAP authentication

For a private/unlisted plan, **Connection settings → Other / private APN**
provides private PAP credential storage. Ordinary carrier presets already supply
public defaults. These are carrier Internet credentials, not the SIM PIN. The
same private storage is available through the administrative API:

```elixir
:ok = NervesGate.Cellular.save_authentication("operator.apn", username, password)
# Observe status.cellular.operation and .result for storage completion.
# Change APN using a normal network trial; verify cellular Internet separately.
:ok = NervesGate.Cellular.forget_authentication()
```

Saving accepts one explicit APN, a 1–64 character username and a 0–64 character
password. Credentials must be printable ASCII without quotes or backslashes.
Saving and forgetting share Network's admission/worker, but are private storage
operations, not connectivity trials; network rollback does not undo them. They
do not interrupt an active data session. Saving needs the qualified, present
modem but not an enabled data source; forgetting also works while absent.

Save credentials for the exact carrier APN, then use **Connection settings** to apply
that APN. If the APN is already applied, use **Reconnect 4G** (API:
`NervesGate.Cellular.reconnect/0`). Reconnection is explicit, interrupts cellular
traffic and may disconnect remote management. It reconfigures only the qualified
cellular interface without persisting a different network configuration or
changing PIN protection. Saving credentials never triggers it automatically.

The EC100 modem driver checks SIM READY before starting a data call. It releases
only its own previous packet context, selects the carrier/APN, writes `CGDCONT`
and checks the reported APN before sending `QICSGP` (IPv4, PAP mode 1). An exactly
APN-matched private record overrides the public default; otherwise the selected
carrier's public defaults apply. No credentials means explicitly cleared modem
authentication (mode 0), never stale credentials from a previous connection. It
then uses `QIACT` and `QNETDEVCTL=1,<context>`. Adapter status uses the fourth
response field (PDN state), not the first field (requested connection mode).

Unknown contexts, invalid records or rejected/uncertain setup stop that
activation; credentials are not silently retried without authentication. Normal
ECM reconnects can retry PAP; this is unrelated to the one-attempt SIM PIN policy.
Interface teardown disconnects the adapter and deactivates only its own packet
context, so a new controller can configure a different APN/PAP profile. The
network's separate IMS context is untouched. CHAP and IPv6 contexts are not
supported by this integration.

Credentials live at `["cellular", "authentication"]` in the persistent
`NervesGate.Settings` table. They are **not encrypted**; data-partition backups,
root access and VM crash dumps can expose them. The modem also receives and may
retain them. Forget deletes the private record on successful storage completion
and clears modem authentication before the next fresh packet-context activation,
not during an active session. Factory reset erases the record; the next fresh
packet-context activation clears modem authentication.
Status exposes only `authentication` (`none`, `pap` or `unknown`) and
`authentication_apn`, never the username/password. Interface configurations,
projections and notifications carry no credentials; primary log filtering redacts
credential-bearing AT commands and reports. Do not log API arguments or enter
credentials in a shell history.

The EG800AK supports `QICSGP`, not standard `CGAUTH`. Congstar IPv4/PAP,
registration, DHCP, DNS and cellular-bound Internet connectivity have been
verified on hardware, including automatic connection after a firmware reboot and
reconnection after explicitly deactivating the packet context. TCP checks bound
to `wwan0` prove these checks did not use Ethernet. Registration or a saved PAP
record alone is not proof of Internet access.

Modem identity, AT/ECM commands, SIM recognition after active-high detection setup,
LTE registration and IPv4/PAP data connectivity are qualified on hardware.
Control-only startup, automatic carrier identification and the integrated
PIN-before-connect UI still need hardware qualification, as do live SIM swapping
and Ethernet/cellular failover.

### SIM commissioning and saved PIN

SIM setup is available before cellular data is enabled. Normal setup asks only
for the PIN when needed; Connection settings shows attempts, protection,
registration, operator and signal. Unknown is not proof of a missing SIM, and
Refresh is read-only. USB is not required. SIM controls work over Ethernet, VPN or USB, and through
the administrative [Elixir API](action-api.md). Use HTTPS when connecting remotely.
The UI has no sign-in: anyone with access to it can submit SIM commands, so keep
management access restricted to trusted users. All SIM commands share Network's
single worker, and VintageNetECM remains the only AT-port user.

- **Unlock and connect** sends one 4–8 digit PIN. After success and a fresh
  READY/identity check, the PIN is saved bound to a hash of the SIM's ICCID.
- A ready SIM with PIN protection disabled needs no unlock PIN. It does not offer
  PIN verification/storage. Protection changes require the administrative API.
- **Remember PIN** on Connection settings is available only for a ready, PIN-protected SIM. It
  verifies the current PIN with one `CPWD` command that retains the same value;
  it never treats reapplying an unchanged protection setting as verification.
  **A wrong PIN consumes an attempt.**
- The administrative API changes the PIN or turns protection on or off, once. Unchanged or
  unknown protection settings are rejected before sending a PIN. A protection
  change must be freshly confirmed before remembering/forgetting the PIN. After
  an unknown PIN-change outcome, never try both codes blindly.
- **Forget saved PIN** deletes the record without touching the SIM.

PUK, PIN2, SMS and USSD are unsupported; recover a blocked SIM with the carrier or
a phone. SIM operations are not network trials and rollback does not undo them.

`cellular.operation` reports current work; `cellular.result` retains the last
command's operation and error (nil on success). Automatic observation refreshes
never erase that result. A PIN failure clears potentially stale SIM/attempt
observations until they are read again. The UI distinguishes working, completed
and failed commands, clears credential forms after submission, and never recovers
those forms on reconnect. A storage failure reports unknown saved state and blocks
PIN use or PAP activation instead of claiming an in-memory change is durable.

After a restart, the saved PIN is sent automatically only when the SIM asks for it
and its fresh identity matches. The record is blocked *before* that single attempt
and re-armed only by a known success, so a failed or uncertain attempt stays
blocked across reboots and no PIN is ever retried blindly. If the modem cannot
report the ICCID while locked, nothing is sent and manual unlock is required.

The record is `["cellular", "pin"]` in the persistent `NervesGate.Settings`
property table under `/data/nerves_gate/settings`. That table holds small
device-local values with no better owner; network configuration stays in
VintageNet. It is **not encrypted**: root access, full eMMC backups and VM crash dumps can expose it.
Status, projections, notifications and logs never contain the PIN or SIM identity.
Factory reset erases it.

## Saving and rollback

Internet and application enablement have separate UI drafts but one Network
owner and one saved configuration. All pages show the same active trial and timer. Saving
checks the draft's original configuration inside Network; stale drafts are rejected
and must be reloaded.

The administrative `Network.propose/2` API accepts independent Internet/application
ports only. Hardware edits application enablement. All platform changes are blocked
while an app lease or unknown cleanup exists; apps must release first. 4G backup
needs an Ethernet uplink.

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
place; it needs no cable, DHCP lease or Internet. Observed Internet/application/USB
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

Connect requires `NervesTime.sync_status().synchronized?` to be true so TLS
certificate validation uses synchronized system time. While waiting, the page
shows “Waiting for system time synchronization.” and disables Connect. Once time
is synchronized, submit Connect explicitly; rejected requests are not replayed.
Losing time synchronization does not disconnect an existing session or block
renaming and disconnecting.

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

For application-owned access, use the optional Tailnet subnet-router app and its
process-owned SDK lease. It journals ownership before advertisement, refuses a
pre-existing advertisement and withdraws only its own route before removing the
local address. Owner loss schedules cleanup; failed/uncertain cleanup retains the
journal and blocks reuse. No write is replayed automatically. Approval remains
unknown until verified externally; advertised does not mean approved or reachable.

`NervesGate.Equipment.scan/label/share/unshare` are removed. Applications own
equipment discovery/identity and explicit route requests through their leases.
Approve the advertised route in Tailscale and restrict it in tailnet policy.
Linux clients need `tailscale set --accept-routes`. This is routed access, not
an Ethernet bridge or broadcast discovery.

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

**Overview → Remote access → Developer runtime** shows the node name. Runtime
credentials require an explicit reveal and can be hidden again. Anyone who can
read the page and reach these ports can run arbitrary code on the gateway. The
cookie comes from the explicit private `NervesGate.Distribution.cookie/0` read,
cached only by the requesting view, never `NervesGate.status()` or broadcasts.
Cookie display is not USB-only: restrict every management interface to trusted
users. USB verification for first-network auto-save/password recovery is separate.

OTP creates `$HOME/.erlang.cookie` (normally `/root/.erlang.cookie`) on the data
partition: it survives reboots and updates, and factory reset erases it. `MIX_ENV=dev`
builds use the public `:mycookie` instead; use them only on trusted development
networks. To share a cookie across production nodes, provision that file with
identical contents and owner-only permissions, then reboot. Connect nodes
explicitly with `Node.connect(:"nerves_gate@100.64.0.2")`.

Run Livebook on another computer as an **Attached node** with the shown name and
cookie, using the same Elixir minor and a compatible OTP (Elixir 1.20 / OTP 29).
Attached runtimes cannot install dependencies, so add libraries to firmware.
Permanent equipment sessions belong in their owning application's supervision tree, not a notebook.

## Observations

Internet status comes only from permitted interfaces, never USB or the global best
connection. Unconfigured or application-only networking does not require Internet.
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
`NERVES_GATE_SSH_KEYS` populates `:nerves_gate, :ssh_keys`, which seeds the store
only on first use or after factory reset. No older key store is imported. A
persisted empty store stays empty. Use `NervesGate.SSH.add_key/1` and
`NervesGate.SSH.remove_key/1`, not NervesSSH's key APIs.

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
