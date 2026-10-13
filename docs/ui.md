# Connections and equipment

Navigation is **Overview · Equipment**, with a small **Device** link.
Open a connection or physical port to see its settings and diagnostics. There is
no separate Settings tree or Remote access navigation item.

## Implemented foundation

| Page | Route | Purpose |
| --- | --- | --- |
| Overview | `/` | Three compact cards: Internet, Remote access, Erlang distribution |
| Internet | `/network` | Network status, port roles, addressing, cellular source, backup and APN |
| Remote access | `/remote` | Tailscale status, addresses, enrollment, private sign-in, hostname and disconnect |
| Erlang distribution | `/distribution` | Node, cookie and connection instructions; no cookie on Overview |
| Equipment | `/equipment` | Physical ports ordered LAN, RS485, CAN |
| LAN 1 / 2 | `/equipment/lan/1`, `/equipment/lan/2` | Port status, neighbor observations, bounded ARP scan, labels and subnet sharing |
| RS485 1 / 2 | `/equipment/rs485/1`, `/equipment/rs485/2` | Diagnostic opt-in, passive capture and one-shot Modbus reads |
| CAN 1 / 2 | `/equipment/can/1`, `/equipment/can/2` | Listen-only configuration, counters and bounded capture |
| Device | `/device` | Firmware/runtime information, identify, collapsed button/LED help |

LAN 1 always means `eth0`, LAN 2 `eth1`. Equipment hides a port assigned solely
to Internet without renumbering the remaining port. Unassigned ports stay visible
as not configured. Both RS485 and both CAN buses stay visible even when disabled
or unavailable. Route IDs use a fixed allowlist, never arbitrary device names.

In shared mode both LAN ports belong to one network; the device list and scan are
network-wide, not attributed to either port. There is still only one equipment
network scope, not multiple independent equipment subnets.

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
a page never starts a scan or remote sharing. Remote access manages the gateway;
the dedicated equipment LAN page manages subnet sharing. Neither claims that
advertised routes are approved or reachable. Unrelated routes are preserved.
Missing daemon observations are reported as unknown, not as sharing being disabled.

First-time setup reuses the Internet detail page, including trusted USB auto-save and
manual rollback. Unconfirmed network changes remain visible on every other page,
with a direct link back to keep or restore them. Navigation updates after live
transitions; disconnected views indicate potentially stale status.

Old `/settings`, `/settings/*` and `/equipment/buses` routes are removed, as are
`/setup` and `/internet`; use the routes above. Network configuration is shared
across ports through the Internet page rather than duplicated in LAN editors. No device scans, route
mutations, bus traffic or physical I/O are started by visiting a page.

## Equipment sharing

The dedicated equipment LAN page shows its confirmed IPv4 subnet and one on/off
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

Device's collapsed help explains RUN/application, USER1/Internet + Tailscale health and USER2/Alarmist severity patterns, fixed
release-only gestures, and the most recent recovery error. **Identify gateway**
blinks for five seconds and resumes current status. Kernel-triggered LEDs are left
untouched. Button-mode selectors have been removed; there is no web recovery action.
Host mode simulates LEDs, button and recovery without opening hardware or erasing files.

See [LED meanings, exact button thresholds and recovery limits](indicators.md).
EC100 reboot and factory reset use standard Nerves APIs. Reset removes all saved
application data; physical qualification is pending. Startup/input loss requires
a release before gestures arm.

## Bus observation and diagnostics

Each bus page distinguishes unsupported targets, missing kernel devices,
disabled interfaces and active operations. CAN status reports observed bitrate,
listen-only mode, controller state and counters. Explicit captures are receive-only,
limited to five seconds / 200 frames. CAN settings only enable listen-only mode.
RS485 capture is limited to five seconds / 4096 bytes at the qualified 9600 8N1 profile.
The Modbus form requires renewed authorization for one read of 1–32 registers using
function 3 or 4. There are no broadcasts, writes, scans, automatic retries or polling.

The per-bus controls change live CAN state without persistence, and enable RS485 diagnostic
access until service restart. No UART is opened merely by enabling it. Only
can0/can1 and ttyS3/ttyS4 are eligible; UART0 remains untouched. Empty captures and
device presence are not health or reachability checks. Remote bus access still
requires a separate service/protocol bridge and is not provided.
See [bus limits and qualification](buses.md).

Host mode remains isolated simulation. The existing trusted-network HTTP exposure,
CSRF/origin safeguards, and independent USB recovery behavior are unchanged.
