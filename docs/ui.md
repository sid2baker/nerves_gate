# Operations and commissioning

The UI separates everyday observation/access from occasional configuration.
Navigation is **Overview · Equipment · Remote access · Settings**.

## Implemented foundation

| Page | Route | Purpose |
| --- | --- | --- |
| Overview | `/` | Current equipment, remote and Internet connection summaries |
| Equipment | `/equipment` | Scoped neighbor observations, bounded ARP scan, local labels and gateway addresses |
| Bus workspace | `/equipment/buses` | Bounded CAN/RS485 captures and one-shot Modbus register reads |
| Remote access | `/remote` | Gateway Tailscale addresses and equipment subnet sharing on/off |
| Settings | `/settings` | Configuration entry points, button/LED controls and device information |
| Network settings | `/settings/network` | Ethernet/cellular source, optional 4G backup, APN and equipment configuration |
| Tailscale settings | `/settings/tailscale` | Enrollment, private sign-in, hostname and disconnect |
| Bus settings | `/settings/buses` | CAN listen-only bitrate and RS485 diagnostic opt-in |

Equipment observations are **not a complete inventory or reachability test**.
The neighbor cache supplies IP, MAC and last-seen time (unknown for static entries).
Labels follow a MAC only within the confirmed interface/subnet/gateway scope and
are not authenticated device identities. Observations are capped at 256; absent
entries age out after 15 minutes. Up to 256 labels persist under
`/data/nerves_gate/equipment_labels.json` on firmware; host mode uses memory only.

The explicit ARP-only scan requires a confirmed static equipment address and a
matching observed link/topology. It probes at most the /24 containing the gateway,
for at most five seconds, with no TCP/UDP port probes. LAN trials and scans cannot
overlap; scan failure does not restore or change network settings. Merely opening
a page never starts a scan or remote sharing. Remote access distinguishes
access to the gateway from equipment routing: it does not claim that advertised
routes are approved or reachable. Unrelated routes are preserved.
Missing daemon observations are reported as unknown, not as sharing being disabled.

First-time setup reuses Network settings, including trusted USB auto-save and
manual rollback. Unconfirmed network changes remain visible on every other page,
with a direct link back to keep or restore them. Navigation updates after live
transitions; disconnected views indicate potentially stale status.

There are no compatibility routes for `/setup` or `/internet`. Network/Tailscale
configuration is not duplicated on the operational pages. No device scans, route
mutations, bus traffic or physical I/O are started by visiting a page.

## Equipment sharing

Remote access shows the confirmed dedicated equipment IPv4 subnet and one on/off
control. There are no site IDs, address calculators or arbitrary route controls.
Use equipment's normal IPv4 addresses; discovery is optional. Overlaps with other
sites, the client's LAN or another VPN are unsupported. Broadcast discovery is not
bridged. Route approval/access policy and reachability remain separate checks.

Off removes only that equipment subnet, including an uncertain write, without
changing other advertisements, enrollment or running intent. Unknown is not shown
as Off; the operator can explicitly turn sharing off to verify withdrawal. Any
remaining external advertisements must be removed in Tailscale before LAN changes.
The UI reports advertisement state, not proof that existing sessions have ended;
see [networking.md](networking.md#equipment-sharing) for the limits.

## Button and LEDs

Settings explains RUN/application, USER1/Internet + Tailscale health and USER2/Alarmist severity patterns, fixed
release-only gestures, and the most recent recovery error. **Identify gateway**
blinks for five seconds and resumes current status. Kernel-triggered LEDs are left
untouched. Button-mode selectors have been removed; there is no web recovery action.
Host mode simulates LEDs, button and recovery without opening hardware or erasing files.

See [LED meanings, exact button thresholds and recovery limits](indicators.md).
EC100 reboot and factory reset use standard Nerves APIs. Reset removes all saved
application data; physical qualification is pending. Startup/input loss requires
a release before gestures arm.

## Bus observation and diagnostics

The bus workspace distinguishes unsupported targets, missing kernel devices,
disabled interfaces and active operations. CAN status reports observed bitrate,
listen-only mode, controller state and counters. Explicit captures are receive-only,
limited to five seconds / 200 frames. CAN settings only enable listen-only mode.
RS485 capture is limited to five seconds / 4096 bytes at the qualified 9600 8N1 profile.
The Modbus form requires renewed authorization for one read of 1–32 registers using
function 3 or 4. There are no broadcasts, writes, scans, automatic retries or polling.

Settings change live CAN state without persistence, and enable RS485 diagnostic
access until service restart. No UART is opened merely by enabling it. Only
can0/can1 and ttyS3/ttyS4 are eligible; UART0 remains untouched. Empty captures and
device presence are not health or reachability checks. Remote bus access still
requires a separate service/protocol bridge and is not provided.
See [bus limits and qualification](buses.md).

Host mode remains isolated simulation. The existing trusted-network HTTP exposure,
CSRF/origin safeguards, and independent USB recovery behavior are unchanged.
