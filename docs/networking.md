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
The version-2 file is validated and saved with fsync, atomic rename and mode 0600.
It contains no credentials or observations. Corrupt or unsupported files are not
overwritten. Version-1 files migrate in memory to the explicit shared arrangement;
upgrading does not silently split an installed LAN. The legacy `ethernet` format
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

Network's GenServer owns the timer, not the browser. Only committed settings are
saved. Restarting the manager or rebooting cancels pending changes and restores the
last saved state. Failed applies/saves roll back; failed restores are retried.
The previous configuration is made durable before touching interfaces. VintageNet
retries asynchronous interface failures and owns interface hotplug and cleanup.

## Tailscale

In **Tailscale**, enter a device name, select **Connect Tailscale**, then follow the
private sign-in link. Return to see connection or machine-approval status. No auth
key is needed. Once connected, the address is shown first; rename and disconnect
are under **Device name and connection**. Disconnecting interrupts a browser using
that VPN. USB and LAN remain available. These operations do not use Ethernet's
rollback timer.

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
`printf` commands) and once during the isolated DHCP-to-static test. VintageNet
retries interface failures; a failed network trial is rejected and restored, not
reported as saved. The complete integration test also passed, but that does not
eliminate this upstream command-runner race. The repository does not monkey-patch
MuonTrap or suppress the failure.
