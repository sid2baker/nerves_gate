# Networking and recovery

## Port roles

Port 1 is `eth0`; Port 2 is `eth1`. On a fresh gateway, both independently try
DHCP. A single verified Internet port is suggested first; otherwise a single
linked, addressed port is suggested. Ambiguous connections require a choice.
Internet probes are interface-bound: a cable or DHCP lease is not proof of Internet.

Saved assignments never change automatically when a cable disappears or moves.
Use **Network** to change them. Neither setup nor discovery bridges networks,
enables failover or assigns an equipment address behind your back.

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

This does not change equipment addresses, run an Ethernet DHCP server, configure
NAT or enable equipment subnet forwarding. Joining/splitting ports interrupts
Ethernet traffic. USB is never part of these changes.

## Saving and rollback

Settings are stored at `/data/nerves_gate.json` (host: `tmp/dev/nerves_gate.json`).
The version-2 file is validated and saved using an exclusive temporary file, file
fsync, atomic rename, directory fsync and mode 0600. It contains no credentials or
observations. Without a valid recovery journal, corrupt or unsupported files fail
closed and are not overwritten. Version-1 files migrate in memory to the explicit
shared arrangement; upgrading does not silently split an installed LAN. The legacy `ethernet` format
also remains readable; new separate-port saves use `ports`.

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

### Durable trial protocol

The Network Jido agent chooses normal trial progression: await manual confirmation,
wait for readiness, auto-save verified USB setup, or reject a subnet conflict.
Its safety runtime executes those requests only after fresh checks; it never
substitutes a different normal-path decision when an observation has changed.
An independent watchdog and bounded hardware worker belong to that runtime, not
the browser or a Jido timer. A versioned journal at `/data/nerves_gate.json.trial` stores the trial ID,
previous/requested configurations, auto-save flag, phase and informational expiry.
It contains no daemon identity or observations.

1. **Propose:** durably save previous settings, then the pending journal, before
   touching LAN interfaces. Acknowledge only after successful application.
2. **Confirm:** recheck ID, monotonic deadline, readiness and subnet conflicts.
   Sync requested settings, then sync a `confirmed` journal marker. **That marker
   is the commit point.** Delete the journal afterward as cleanup.
3. **Cancel, timeout, failed apply or interrupted pending work:** stop and join
   the worker, then restore previous disk and hardware settings.
4. **Restart/reboot:** read the journal before accepting commands. Pending means
   restore previous settings; confirmed means finish the requested commit.
   Never resume a countdown using a potentially incorrect wall clock.

A crash between writing requested settings and the confirmed marker still restores
previous settings. An uncertain marker write is reconciled from the journal, not
blindly treated as a rollback. Failed cleanup after a confirmed decision blocks
new proposals but does not undo that decision. Recovery keeps its journal until
both disk and hardware restoration succeed; it attempts hardware restoration even
if persistence is temporarily unwritable. Repeated recovery is idempotent.

An agent crash interrupts active trial work and triggers recovery. A runtime crash
kills its linked worker and restarts the agent only after startup recovery.
Unsuccessful recovery remains visible and is retried with new proposals blocked.
A valid journal can recover even a damaged primary settings file; a corrupt
journal fails closed. Do not delete a journal simply to clear a UI error.

VintageNet still owns interface state, hotplug, cleanup and asynchronous retries.
An admitted VintageNet operation can outlive its caller, so the adapter retains
its bounded configuration/settlement barrier. No signal-delivery or agent-memory
guarantee is required for rollback. USB is outside the journal's LAN operations.

## Tailscale

In **Tailscale**, enter a device name, select **Connect Tailscale**, then follow the
private sign-in link. Return to see connection or machine-approval status. No auth
key is needed. Once connected, the address is shown first; rename and disconnect
are under **Device name and connection**. Disconnecting interrupts a browser using
that VPN. USB and LAN remain available. These operations do not use Ethernet's
rollback timer.

Remote's Jido agent admits one operation at a time; its supervised runtime owns a
bounded, linked daemon worker. Acceptance does not mean completion. Agent/runtime
crashes or timeouts stop the worker and report uncertainty; startup only observes
the daemon, never replays a connect/rename/logout. Daemon-side work may still have
completed, so read status before retrying.

The Tailscale OTP application supervises `/usr/sbin/tailscaled` in kernel mode.
Kernel TUN support is required. Identity and settings stay daemon-owned in
`/data/tailscale_ex`; the socket is `/run/tailscale/tailscaled.sock`. Starting the
daemon does not enroll it or enable equipment routing. Firmware builds preserve
existing enrollment rather than resetting preferences.

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
hosts. The UI does not advertise equipment subnets, enable forwarding, grant
tailnet permissions, configure Serve/Funnel or verify equipment reachability.

## Observations and connectivity policy

LiveViews subscribe to existing VintageNet/Tailscale properties and application
workflow metadata, not a central snapshot server. Significant workflow facts are
best-effort Jido Signals; periodic reconciliation repairs missed observations.
Private login URLs are excluded from these subscriptions.

Alarmist derives Internet unavailability from the selected Internet role,
observed connectivity and observation-source availability. Unconfigured or
explicitly equipment-only networking does not require Internet. Connectivity's
Jido agent performs at most three bounded **read-only** rechecks per outage per
agent lifetime. Restarting its input preserves the remaining budget; restarting
the whole agent starts a new bounded budget. There is no automatic reconfiguration,
DHCP restart, VPN reconnect, enrollment, failover or DNS reset.

## Local recovery and HTTP exposure

Firmware listens on **all IPv4 interfaces, port 4000**. The listener starts without
USB and accepts connections on interfaces added later. This does not configure an
address or enroll a VPN. Host preview listens only on `127.0.0.1`.

For USB recovery, open `http://<gateway-usb-address>:4000/settings`. VintageNetDirect
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
verification, not only host simulation.

## Known runtime limitation

With host OTP 29.1, MuonTrap can intermittently exit with `:epipe` when a short-lived
command finishes. This was reproduced independently of networking (55 of 2,000
`printf` commands) and during isolated network integration runs. VintageNet
retries interface failures; a failed network trial is rejected and recovery is
attempted, not reported as saved. A crashed interface can also delay recovery.
The final Jido integration run passed all 14 checkpoints, but that does not
eliminate this upstream command-runner race. The repository does not monkey-patch
MuonTrap or suppress the failure. See [architecture](architecture.md) for the
remaining dependency and verification limitations.
