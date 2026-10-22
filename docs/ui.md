# Gateway UI

EC100 and QEMU devices serve the same UI from `lib/nerves_gate_web/`;
`mix dev.ui <target>` serves it on the workstation with code reload.

Navigation is **Overview · Equipment · Settings**. Open a connection or physical
port for its settings and diagnostics. Pages share the device-owned projection;
form drafts stay separate from live observations.

## Pages

| Page | Route | Purpose |
| --- | --- | --- |
| Overview | `/` | Internet, Remote access and Erlang distribution cards |
| Internet | `/network` | Internet port/address, cellular source, backup and APN |
| Remote access | `/remote` | Tailscale enrollment, private sign-in, hostname and disconnect |
| Erlang distribution | `/distribution` | Node, cookie and connection instructions |
| Equipment | `/equipment` | Physical ports ordered LAN, RS485, CAN |
| LAN 1 / 2 | `/equipment/lan/1`, `/equipment/lan/2` | Equipment address, neighbors, ARP scan, labels and subnet sharing |
| RS485 1 / 2 | `/equipment/rs485/1`, `/equipment/rs485/2` | Opt-in, passive capture and one-shot Modbus reads |
| CAN 1 / 2 | `/equipment/can/1`, `/equipment/can/2` | Listen-only configuration, counters and capture |
| Settings | `/settings` | Separate/joined LAN ports, joined-network address, SSH keys and device information |

Equipment hides a port used solely for Internet without renumbering the other.
Unassigned LAN ports and all buses stay visible, including disabled or unavailable
ones. Route IDs come from a fixed allowlist.

Internet, equipment addressing and LAN arrangement have separate editors with the
same save/undo flow; an unconfirmed trial is visible on every page with a link to
keep or restore it. Disconnected views show unavailable instead of stale actions.
Opening a page never starts scans, route changes, bus traffic or other I/O.

## SSH keys

Paste one OpenSSH public key (Ed25519, RSA or ECDSA), never a private key. Keys
are identified by SHA256 fingerprint, so duplicates are ignored; the device stores
up to 32. Removal needs confirmation and blocks only **new** logins. Removing the
last key leaves USB password access. Incoming observations never overwrite a draft.
See [recovery access](networking.md#local-recovery-and-http-exposure).

## Equipment observations

The neighbor cache supplies IP, MAC and last-seen time (unknown for static entries).
It is **not a complete inventory or reachability test**. Labels follow a MAC only
within the confirmed interface/subnet/gateway scope and are not authenticated
identities. Up to 256 observations are kept; absent entries age out after 15
minutes. Up to 256 labels persist on the device in
`/data/nerves_gate/equipment_labels.json`.

In shared mode both LAN ports form one equipment network, so devices and scans are
not attributed to a port. Multiple equipment subnets are not supported.

The explicit ARP scan requires a confirmed static equipment address and matching
link and topology. It probes at most the gateway's /24 for five seconds, without
TCP/UDP port probes. Scans cannot overlap LAN trials and never change settings.

## Controls

- **Sharing:** the equipment LAN page controls its confirmed IPv4 subnet. Unknown
  is not Off. See [equipment sharing](networking.md#equipment-sharing).
- **Buses:** pages distinguish unsupported targets, missing devices, disabled ports
  and active operations. See [CAN/RS485](buses.md).
- **Identify** (Settings) blinks the status LEDs, then resumes current patterns.
  There is no web reboot or reset. See [LEDs and button](indicators.md).

Workstation UIs send commands to the selected device. QEMU reports EC100
peripherals as unavailable. The UI has no sign-in; see
[HTTP exposure](networking.md#local-recovery-and-http-exposure).

## Developer workbench

Root `mix dev [APP_DIRECTORY]` serves `lib/dev_web/` at localhost:4000. A shared
sidebar separates the local developer workflows:

| Page | Route | Purpose |
| --- | --- | --- |
| Overview | `/` | Summaries, shortcuts and current operation; no configuration forms |
| Devices | `/devices` | One searchable directory of physical gateways and owned QEMU devices; All/Physical/Simulated filters |
| Physical device | `/devices/physical/:address` | Explicit verified-SSH information read and gateway link; Firmware tab with local-image dropdown and typed update confirmation |
| Simulated device | `/devices/:id` | Observations, gateway link, injected faults and Tests & controls tab |
| Applications | `/apps`, `/apps/:id` | Create/open ordinary SDK projects; per-app test, package and simulator installation |
| Firmware | `/firmware` | Explicit EC100/QEMU builds, output and image paths; building never installs |
| Factory provisioning | `/factory` | Initial EC100 USB MASKROM installation; explicit RAM-loader review, mandatory full backup, physical-board acknowledgement and typed erase confirmation |
| Simulator | `/simulator` | Bench-wide Start/Stop/Reset, virtual wiring, scenario runs and action log |

The **Simulated · QEMU** badge is assigned only from owned simulator inventory,
not editable tags, names or network advertisements. Physical discovery entries
remain unverified even if they advertise a QEMU target. Missing device information
is not inferred from a local build: use **Read device information** to explicitly
query a physical gateway over authenticated SSH on port 22. Only public identity
fields and their read timestamp are retained for the session, not a persistent
connection. Directory rendering never probes devices. Visiting Devices starts a
bounded, read-only mDNS browse. Firmware selection lists local EC100 images with
their actual versions; image integrity and compatibility are rechecked during
review, never assumed from an option label.

Apps are ordinary directories, not solutions. Physical devices never receive
QEMU drivers, faults or disk-reset controls. Their firmware updates require a
separate authenticated SSH review and explicit typed confirmation. Initial USB
provisioning lives on its own page, never on a discovered device's update form;
opening it never probes USB. See [firmware updates](firmware-updates.md). Page navigation does not cancel work or
expire an otherwise valid review: operations belong to the backend, with status
and expandable output visible across pages. Opening a page never starts devices,
builds firmware or sends updates. UI and CLI invoke the same operations; backend
admission remains authoritative. See [development](development.md).

Both UIs share committed firmware assets. Firmware's Tailwind configuration scans
root `../lib/`; rebuild and commit `firmware/priv/static/assets/` after workbench
template/class changes. This is a build-time source dependency, not a device
runtime dependency.
