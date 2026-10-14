# UI and equipment

Navigation is **Overview · Equipment**, with a small **Device** link. Open a
connection or physical port for settings and diagnostics. All pages use the same
device-owned projection; local form drafts remain separate from live observations.

## Pages

| Page | Route | Purpose |
| --- | --- | --- |
| Overview | `/` | Internet, Remote access and Erlang distribution cards |
| Internet | `/network` | Port roles, addressing, cellular source, backup and APN |
| Remote access | `/remote` | Tailscale enrollment, private sign-in, hostname and disconnect |
| Erlang distribution | `/distribution` | Node, cookie and connection instructions |
| Equipment | `/equipment` | Physical ports ordered LAN, RS485, CAN |
| LAN 1 / 2 | `/equipment/lan/1`, `/equipment/lan/2` | Neighbors, ARP scan, labels and subnet sharing |
| RS485 1 / 2 | `/equipment/rs485/1`, `/equipment/rs485/2` | Opt-in, passive capture and one-shot Modbus reads |
| CAN 1 / 2 | `/equipment/can/1`, `/equipment/can/2` | Listen-only configuration, counters and capture |
| Device | `/device` | Runtime information, identify and button/LED help |

LAN 1 is always `eth0`, LAN 2 `eth1`. Equipment hides a port assigned solely to
Internet without renumbering the other port. Unassigned LAN ports and both buses
of each type remain visible, including disabled or unavailable ports. Route IDs
use a fixed allowlist, never arbitrary device names.

First setup and later network changes use the same Internet page. Unconfirmed
trials stay visible on other pages with a link to keep or restore settings.
Disconnected views show unavailable rather than continuing to offer stale actions.
Opening a page never starts scans, route changes, bus traffic or physical I/O.

## Equipment observations

The neighbor cache supplies IP, MAC and last-seen time (unknown for static entries).
It is **not a complete inventory or reachability test**. Labels follow a MAC only
within the confirmed interface/subnet/gateway scope; they are not authenticated
identities. Observations are capped at 256 and absent entries age out after 15
minutes. Up to 256 labels persist in `/data/nerves_gate/equipment_labels.json` on
the device. The workstation has no separate equipment store.

In shared mode, both LAN ports belong to one equipment network. Devices and scans
are network-wide, not attributed to a port. Multiple independent equipment subnets
are not supported.

The explicit ARP scan requires a confirmed static equipment address and matching
observed link/topology. It probes at most the /24 containing the gateway for five
seconds, with no TCP/UDP port probes. Scans cannot overlap LAN trials; scan failure
does not change or restore network settings.

## Controls and safety

- **Sharing:** the dedicated equipment LAN page controls its confirmed IPv4 subnet.
  Unknown is not Off. Approval, access policy and reachability remain separate;
  see [equipment sharing](networking.md#equipment-sharing).
- **Buses:** pages distinguish unsupported targets, missing devices, disabled ports
  and active operations. See [CAN/RS485 limits](buses.md) before enabling diagnostics.
- **Device:** Identify blinks available status LEDs, then resumes current patterns.
  There is no web reboot/reset action. See [LEDs and physical gestures](indicators.md).

The workstation is a UI client, not a hardware simulator. QEMU reports unavailable
EC100 peripherals honestly. HTTP is unauthenticated; see
[deployment and recovery access](networking.md#local-recovery-and-http-exposure).
