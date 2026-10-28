# Gateway UI

EC100 and QEMU devices serve the same UI from `firmware/lib/nerves_gate_web/`.
Open the device's gateway URL, linked from the developer workbench. Gateway
Elixir/HEEx changes require rebuilding firmware; use disposable QEMU devices for
this development loop.

Navigation is **Overview · Plugins · Hardware · Settings**. The gateway is a managed edge
plugin host: it exposes physical resources and owns shared infrastructure;
plugins own equipment identities, protocol connections and data collection.
Open a connection or physical port for platform settings and diagnostics. Pages share the device-owned projection;
form drafts stay separate from live observations. The shared read model is schema
v11 (`device` availability, `remote` observations and domain-qualified actions).
Gateway views subscribe to the local source before reading, clear availability
on owner loss and obtain a fresh snapshot on resubscription.

## Pages

| Page | Route | Purpose |
| --- | --- | --- |
| Overview | `/` | Internet and unified Remote access; actionable storage warnings |
| Internet | `/network` | Internet port/address, detected 4G sources, network-default APN with advanced override, SIM commissioning |
| Remote access | `/remote` | Tailscale enrollment and private sign-in; advanced runtime access with explicit credential reveal |
| Plugins | `/plugins` | Firmware-bundled plugins: version selection, start/stop and status |
| Plugin page | `/plugins/:app` | Optional plugin LiveComponent while its activation runs |
| Hardware | `/hardware` | Free non-Internet LANs, RS485 and CAN; exclusive plugin assignments |
| LAN 1 / 2 | `/hardware/lan/1`, `/hardware/lan/2` | Link observations and reviewed exclusive assignment; Internet/management ports cannot be acquired |
| RS485 1 / 2 | `/hardware/rs485/1`, `/hardware/rs485/2` | Availability and reviewed exclusive plugin assignment |
| CAN 1 / 2 | `/hardware/can/1`, `/hardware/can/2` | Availability and reviewed exclusive plugin assignment |
| Settings | `/settings` | SSH keys, plugin storage, device information and maintenance |
| Plugin storage | `/settings/storage` | Card commissioning, readiness and explicit format confirmation |

Hardware excludes Internet uplinks and joined Ethernet links from assignable ports.
Free LANs and all buses remain visible, including disabled or unavailable ones.
A direct Internet-LAN URL explains the reservation and offers no assignment form.
Route IDs come from a fixed allowlist. Only the routes above are supported;
replaced URLs are not aliases.

Internet settings use the device-owned save/undo flow; an unconfirmed trial is
visible on every page with a link to keep or restore it. Ethernet permission uses
the same checked whole-plugin stop and reviewed assignment as RS485/CAN, not a
second network enablement form. No advanced topology expander or local addressing/sharing form
is exposed in Hardware. Disconnected views show unavailable instead of stale actions.
Opening a page never starts scans, route changes, bus traffic or other I/O.

## SSH keys

Paste one OpenSSH public key (Ed25519, RSA or ECDSA), never a private key. Keys
are identified by SHA256 fingerprint, so duplicates are ignored; the device stores
up to 32. Removal needs confirmation and blocks only **new** logins. Removing the
last key leaves USB password access. Incoming observations never overwrite a draft.
See [recovery access](networking.md#local-recovery-and-http-exposure).

## Hardware and plugin ownership

The standard UI configures gateway interfaces, not connected equipment. Equipment
names, Modbus units/registers, S7 endpoints and polling belong to plugins.
There is no equipment-label editor or Modbus register form in Hardware. The
network observations remain available independently; built-in bus diagnostics are removed.

Ethernet addressing, routes and bridging remain Network-owned. An assigned LAN
starts without IPv4, DHCP, DNS, a default route or bridge. Its plugin requests isolated
local addressing through a process-owned SDK claim; active or unresolved claims block
platform network changes. Disabled independent ports are explicitly held down.
Saved legacy joined/equipment configurations are rejected and retained for explicitly
authorized administrator migration, never silently converted or erased.
The optional [Tailnet subnet-router plugin](../plugins/tailnet_subrouter/README.md)
provides explicit local configuration and advertisement, disabled on every startup.
Serial/CAN ports have exclusive persistent plugin assignments; Hardware shows the
assigned plugin and its lifecycle state, not protocol or capture controls. A plugin
may own multiple ports. Reassignment explicitly stops both affected plugins and
leaves them stopped after checked cleanup. UI controls never replace backend
admission. EM300/extension-card enumeration is not implemented. See [hardware](hardware.md).

Equipment label/scan/share commands are removed. A passive neighbor-cache read model
belongs to plugins, not a platform compatibility API. Hardware has no neighbor
inventory, labels, scan or sharing controls.
The first plugin network API supports one isolated Ethernet claim per gateway.

## Controls

- **Color theme:** the header icon opens System / Light / Dark choices. The
  preference stays in the browser and follows other tabs. Switching works even
  while LiveView is disconnected or browser storage is unavailable. Theme code
  is bundled in the external JavaScript asset; firmware keeps its strict CSP.
- **Subnet routing:** configure and explicitly enable sharing on the subnet-router
  plugin page.
  Advertisement does not prove tailnet approval or reachability; unknown is not Off.
- **SIM PIN:** the Internet page offers Unlock and save PIN when required, on
  Ethernet, VPN or USB. PIN commands are explicit, never replayed on reconnect;
  advanced PIN/security controls appear once the SIM is ready. Use trusted
  management access and HTTPS for remote entry.
- **Hardware:** pages distinguish unsupported targets, missing devices, disabled ports
  and active operations. See [CAN/RS485](hardware.md).
- **Identify** (Settings) blinks the status LEDs, then resumes current patterns.
  There is no web reboot or reset. See [LEDs and button](indicators.md).

Gateway commands call public domain APIs locally on the device serving the page;
there is no remote command backend. Sign-in URLs and distribution cookies are
explicit private reads cached only in the requesting view, never the projection.
Runtime cookies are read only on an explicit reveal in Remote access, retained
only in that requesting view, and cleared on hide, node change or device loss.
Cookie display, like SIM controls, is available over trusted management interfaces,
not restricted to USB. QEMU reports EC100 peripherals as unavailable. The UI has no sign-in; see
[HTTP exposure](networking.md#local-recovery-and-http-exposure).

## Developer workbench

`mix dev` serves `lib/workbench_web/` at localhost:4000:

| Page | Route | Purpose |
| --- | --- | --- |
| Home | `/` | Resume plugin projects/runs, current job and bench problems |
| Devices | `/devices` | Verified gateways and disconnected candidates with last-seen time |
| Gateway | `/devices/:node` | Shared read-only projection, identity and gateway UI link; physical checks and reviewed firmware update |
| Develop → Plugins | `/develop/plugins`, `/develop/plugins/:id` | Create/open SDK plugin projects; QEMU install/run; reviewed physical install leaving plugins stopped |
| Develop → Firmware | `/develop/firmware` | Build, owned QEMU lifecycle/wiring, results and action log |
| Gateway → Scenarios | `/devices/:node/scenarios` | Confirm QEMU runs and inspect results |
| Gateway → Manual debugging | `/devices/:node/manual` | Acquire owned QEMU control, inject reversible faults and release control |
| Provision | `/provision` | Initial EC100 MASKROM provisioning with destructive review, backup and readbacks |

Physical pages offer the separate `Scenarios.physical/0` catalogue: readiness,
operator-assisted Ethernet/4G failover, and physical-button reboot observation.
Checks use distribution and run one at a time through Jobs. Keep management
independent of the link being tested; the operator restores cables and controls
the button. A lost connection or identity change fails the check, never authorizes
another action. There is no automatic physical fixture or reboot command.

Configuration and recovery remain in the gateway's own UI and physical-button
interlock. Firmware updates privately snapshot the image, review identity/health,
plugin artifacts and SSH trust, require one-use typed confirmation, upload once
through SSH, and verify a healthy new boot over distribution. No manual-verification
fallback is retained. See [firmware updates](firmware-updates.md) and
[button recovery](indicators.md).

The main navigation has four destinations: **Home · Develop · Devices · Provision**.
Develop switches between plugins and firmware. Replaced routes are removed,
not retained as aliases. The **Simulated · QEMU** badge comes only from the
simulator's owned inventory, never advertisements or node names.

`Workbench.Gateways` owns discovery, connection and verified identity. All pages
subscribe to its changes; gateway observations come directly from the device-owned
projection stream. Discovery does not occupy the Jobs queue.

Opening a page never starts devices, builds firmware or sends updates. Candidate
sources are LAN mDNS, online Tailnet `nerves-gate*` peers, manual hostnames/IPv4
addresses and owned QEMU. URLs are not accepted. Tailnet discovery reads the local
daemon without changing VPN configuration. Names are hints: cookie connection and
compiled firmware identity checks establish directory membership, not control
authority. Physical gateways never receive QEMU controls. Gateway links use HTTPS
for Tailnet names and port 4000 otherwise.

Operations belong to the backend: navigating away does not cancel them, and their
status links back to their owning workspace from every page. Output stays alongside
that workspace's actions, not in a global expander. Plugin details include
physical installation: package snapshot and read-only distribution review,
then a ten-minute, one-use typed-address confirmation. The new plugin is installed
stopped/disabled; existing installs are rejected rather than upgraded or started.
Identity/boot/storage are rechecked, hash validation and new-plugin admission happen
inside the device's Plugins owner, and uncertain writes are never automatically retried.
Review/results stay with the plugin, never a firmware confirmation panel.
QEMU installation keeps its separate owned-device reservations and install/run
behavior. Backend admission is authoritative. See [firmware updates](firmware-updates.md)
and [development](development.md).
