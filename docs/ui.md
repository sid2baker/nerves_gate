# Operations and commissioning

The UI separates everyday observation/access from occasional configuration.
Navigation is **Overview · Equipment · Remote access · Settings**.

## Implemented foundation

| Page | Route | Purpose |
| --- | --- | --- |
| Overview | `/` | Current equipment, remote and Internet connection summaries |
| Equipment | `/equipment` | Scoped neighbor observations, bounded ARP scan, local labels and gateway addresses |
| Remote access | `/remote` | Gateway Tailscale addresses, opt-in 4via6 equipment sharing and exact withdrawal |
| Settings | `/settings` | Configuration entry points, button/LED controls and device information |
| Network settings | `/settings/network` | First-time setup and later Ethernet configuration |
| Tailscale settings | `/settings/tailscale` | Enrollment, private sign-in, hostname and disconnect |

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

Remote access can advertise the confirmed dedicated equipment subnet using 4via6.
The operator supplies a tailnet-unique site ID and explicitly confirms authorization.
Observed devices and an optional IPv4 calculator supply copyable IPv6 destinations;
discovery is not required. There is no ordinary IPv4 fallback. Approval/access policy
and actual reachability are separate facts.

Withdraw removes only the selected 4via6 route, including an uncertain write, without
changing enrollment or running intent. LAN proposals remain blocked until routes are
withdrawn and known. No firewall or traffic-isolation status is claimed; see
[networking.md](networking.md#equipment-sharing) for the limits.

## Button and LED

Settings offers **Identify gateway**: blink the mapped EC100 run LED for five seconds
and restore its previous raw value. It does not assign on/off meaning to uncalibrated
polarity. Kernel-triggered LEDs are left untouched. The second programmable LED is
explicitly unsupported until its mapping is verified.

The user button is discovered by `gpio-keys` name and `KEY_PROG1` capability, never a
fixed input number. Its only modes are **Disabled** (default) and **Identify on press**.
Mode is intentionally not persisted: any indicators-service restart disables it.
Presses are edge-detected and rate-limited; releases and repeat/held events cannot
extend an active blink. The last accepted press is shown even when disabled.
There are no reset gestures, network changes, automatic health/sharing modes or
custom assignments. Host mode simulates both controls without opening hardware.

If LED restoration fails, new identify requests are blocked while restoration retries
every five seconds. Graceful shutdown attempts restoration; abrupt VM termination,
power loss, external writers and broken hardware cannot guarantee it. These are
software-tested controls, not a claim of physical LED polarity or on-device validation.

## Next stages — not implemented

1. **Bus observation and diagnostics.** The EC100 has two CAN and two RS485
   interfaces. Treat them as distinct transports, not generic discoverable IP
   devices. Begin with real detected/configured interface status, bounded passive
   CAN capture where supported, and explicitly selected RS485 protocols. RS485
   polling can interfere with another master; do not send automatic discovery
   traffic. Remote bus access requires a separate service/protocol bridge.

Future interface configuration belongs under Settings, while live observation and
use belong under Equipment. Distinguish unsupported software, missing hardware,
disabled interfaces and active operation. Do not ship inactive controls or invent
hardware state merely because a port exists on the EC100.

Host mode remains isolated simulation. The existing trusted-network HTTP exposure,
CSRF/origin safeguards, and independent USB recovery behavior are unchanged.
