# Gateway UI

EC100 and QEMU devices serve the same UI from `firmware/lib/nerves_gate_web/`.
Open the device's gateway URL, linked from the developer workbench. Gateway
Elixir/HEEx changes require rebuilding firmware; use disposable QEMU devices for
this development loop.

Navigation is **Overview · Equipment · Settings**. Open a connection or physical
port for its settings and diagnostics. Pages share the device-owned projection;
form drafts stay separate from live observations. The shared read model is schema
v8 (`device` availability, `remote` observations and domain-qualified actions).
Gateway views subscribe to the local source before reading, clear availability
on owner loss and obtain a fresh snapshot on resubscription.

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
| Application storage | `/storage` | Card commissioning, readiness and explicit format confirmation |

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
- **SIM PIN:** the Internet page offers Unlock and save PIN when required, on
  Ethernet, VPN or USB. PIN commands are explicit, never replayed on reconnect;
  advanced PIN/security controls appear once the SIM is ready. Use trusted
  management access and HTTPS for remote entry.
- **Buses:** pages distinguish unsupported targets, missing devices, disabled ports
  and active operations. See [CAN/RS485](buses.md).
- **Identify** (Settings) blinks the status LEDs, then resumes current patterns.
  There is no web reboot or reset. See [LEDs and button](indicators.md).

Gateway commands call public domain APIs locally on the device serving the page;
there is no remote command backend. Sign-in URLs and distribution cookies are
explicit private reads cached only in the requesting view, never the projection.
Cookie display, like SIM controls, is available over trusted management interfaces,
not restricted to USB. QEMU reports EC100 peripherals as unavailable. The UI has no sign-in; see
[HTTP exposure](networking.md#local-recovery-and-http-exposure).

## Developer workbench

`mix dev` serves `lib/workbench_web/` at localhost:4000:

| Page | Route | Purpose |
| --- | --- | --- |
| Home | `/` | Resume applications/runs, current operation and actionable bench problems |
| Devices | `/devices` | Physical gateways and owned QEMU devices, with filters |
| Physical device | `/devices/physical/:address` | Verified-SSH information read, gateway link and firmware update |
| Simulated device | `/devices/:id` | Read-only observations, gateway link and diagnostic fault/wiring state |
| Develop → Applications | `/develop`, `/develop/applications`, `/develop/applications/:id` | Create/open SDK projects; test, package, install and run on owned QEMU |
| Develop → Firmware | `/develop/firmware` | Build, owned QEMU Start/Stop/Reset and wiring, test/debug device selection, results and action log in one workspace |
| Firmware → Scenarios | `/develop/firmware/scenarios/:id` | Confirm runs and inspect device results; return to the firmware workspace |
| Firmware → Manual debugging | `/develop/firmware/manual/:id` | Explicitly acquire manual control, inject reversible faults, inspect console instructions and release control |
| Provision | `/provision` | Guided initial EC100 USB MASKROM preparation, destructive review and verification |

The main navigation has four destinations: **Home · Develop · Devices · Provision**.
Develop switches between application and firmware workspaces locally. Firmware keeps
build/run/test/results together; no separate test-lab navigation is required. Older
`/test-lab/*` links remain accepted.

The **Simulated · QEMU** badge comes only from the simulator's own inventory, never
from names or advertisements. Discovery and manual additions queue one bounded,
read-only SSH information attempt per new address. These reads share operation
admission with builds and physical updates, and wait while work or a destructive
review is active. Host-key verification and public-key authentication remain
mandatory; there are no password prompts or automatic host-key acceptance. The
directory and device workspace show progress, identity or the failure reason with
**Retry information read**. Refreshing discovery/pages does not retry failed reads
or re-read known identities during the workbench process lifetime. Explicit retries
and information refreshes remain available. Successful USB observations already
provide information and are not automatically queried over SSH.

Opening a page never starts devices, builds firmware or sends updates. The Devices
page starts bounded LAN mDNS and local Tailscale-daemon discovery. Tailnet candidates
are online peers named `nerves-gate` or `nerves-gate-*`; names are hints, not gateway
identity. The local daemon is read through its Unix socket without changing VPN
configuration. If unavailable, the directory still supports LAN and manual entries.
Manual entries accept a hostname/IPv4 address (HTTP port 4000) or a root HTTP(S) URL
with an optional port. Credentials, paths, query strings and fragments are rejected.
An explicit URL survives discovery refreshes; other gateway names can be added
manually. Tailnet candidates use HTTPS MagicDNS links, whose availability depends
on the gateway's Serve configuration. Physical devices never get QEMU controls. The simulated-device page explicitly
subscribes to that owned guest's remote **read-only** projection; it is not a
remote gateway-command proxy.

Operations belong to the backend: navigating away does not cancel them, and their
status links back to their owning workspace from every page. Output stays alongside
that workspace's actions, not in a global expander. Physical application installation
remains a manual SSH workflow. UI and CLI call the same operations,
and backend admission is authoritative. See [firmware updates](firmware-updates.md)
and [development](development.md).
