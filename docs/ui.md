# Gateway UI

EC100 and QEMU devices serve the same UI from `firmware/lib/nerves_gate_web/`.
Open the device's gateway URL, linked from the developer workbench. Gateway
Elixir/HEEx changes require rebuilding firmware; use disposable QEMU devices for
this development loop.

Navigation is **Overview · Equipment · Settings**. Open a connection or physical
port for its settings and diagnostics. Pages share the device-owned projection;
form drafts stay separate from live observations.

## Pages

| Page | Route | Purpose |
| --- | --- | --- |
| Overview | `/` | Internet, Remote access and Erlang distribution cards |
| Internet | `/network` | Internet port/address, detected 4G sources, network-default APN with advanced override, SIM commissioning |
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

- **Color theme:** the header icon opens System / Light / Dark choices. The
  preference stays in the browser and follows other tabs. Switching works even
  while LiveView is disconnected or browser storage is unavailable. Theme code
  is bundled in the external JavaScript asset; firmware keeps its strict CSP.
- **Sharing:** the equipment LAN page controls its confirmed IPv4 subnet. Unknown
  is not Off. See [equipment sharing](networking.md#equipment-sharing).
- **Buses:** pages distinguish unsupported targets, missing devices, disabled ports
  and active operations. See [CAN/RS485](buses.md).
- **Identify** (Settings) blinks the status LEDs, then resumes current patterns.
  There is no web reboot or reset. See [LEDs and button](indicators.md).

Gateway commands run on the device serving the page. QEMU reports EC100
peripherals as unavailable. The UI has no sign-in; see
[HTTP exposure](networking.md#local-recovery-and-http-exposure).

## Developer workbench

`mix dev` serves `lib/dev_web/` at localhost:4000:

| Page | Route | Purpose |
| --- | --- | --- |
| Overview | `/` | Summaries, shortcuts and the current operation |
| Devices | `/devices` | Physical gateways and owned QEMU devices, with filters |
| Physical device | `/devices/physical/:address` | Verified-SSH information read, gateway link and firmware update |
| Simulated device | `/devices/:id` | Observations, gateway link, faults, tests and Manual control |
| Applications | `/apps`, `/apps/:id` | Create/open SDK projects; test, package and install on the simulator |
| Firmware | `/firmware` | EC100/QEMU builds; building never installs |
| Factory provisioning | `/factory` | Initial EC100 installation over USB MASKROM |
| Simulator | `/simulator` | Start/Stop/Reset, virtual wiring, scenario runs and action log |

The **Simulated · QEMU** badge comes only from the simulator's own inventory, never
from names or advertisements. Physical entries are unverified until **Read device
information** queries the gateway over authenticated SSH. Rendering a page never
probes devices, starts devices, builds firmware or sends updates; the Devices page
only starts a bounded mDNS browse. Physical devices never get QEMU controls.

Operations belong to the backend: navigating away does not cancel them, and their
status and output stay visible on every page. UI and CLI call the same operations,
and backend admission is authoritative. See [firmware updates](firmware-updates.md)
and [development](development.md).
