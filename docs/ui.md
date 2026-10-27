# Gateway UI

EC100 and QEMU devices serve the same UI from `firmware/lib/nerves_gate_web/`.
Open the device's gateway URL, linked from the developer workbench. Gateway
Elixir/HEEx changes require rebuilding firmware; use disposable QEMU devices for
this development loop.

Navigation is **Overview · Hardware · Settings**. The gateway is a managed edge
application host: it exposes physical resources and owns shared infrastructure;
applications own equipment identities, protocol connections and data collection.
Open a connection or physical port for platform settings and diagnostics. Pages share the device-owned projection;
form drafts stay separate from live observations. The shared read model is schema
v8 (`device` availability, `remote` observations and domain-qualified actions).
Gateway views subscribe to the local source before reading, clear availability
on owner loss and obtain a fresh snapshot on resubscription.

## Pages

| Page | Route | Purpose |
| --- | --- | --- |
| Overview | `/` | Internet and unified Remote access; actionable storage warnings |
| Internet | `/network` | Internet port/address, detected 4G sources, network-default APN with advanced override, SIM commissioning |
| Remote access | `/remote` | Tailscale enrollment and private sign-in; advanced runtime access with explicit credential reveal |
| Hardware | `/hardware` | All Ethernet, RS485 and CAN ports, availability and use |
| LAN 1 / 2 | `/hardware/lan/1`, `/hardware/lan/2` | Link observations and explicit application access enable/disable; no address/topology editor |
| RS485 1 / 2 | `/hardware/rs485/1`, `/hardware/rs485/2` | Availability, exclusive-use status and passive capture |
| CAN 1 / 2 | `/hardware/can/1`, `/hardware/can/2` | Shared subscription count, listen-only configuration, counters and capture |
| Settings | `/settings` | SSH keys, application storage, device information and maintenance |
| Application storage | `/settings/storage` | Card commissioning, readiness and explicit format confirmation |

Hardware keeps Internet uplinks, unassigned ports and all buses visible, including
disabled or unavailable ones. Roles explain use without hiding physical connectors.
Route IDs come from a fixed allowlist. Only the routes above are supported;
replaced URLs are not aliases.

Internet settings and Ethernet application enablement use the same device-owned
save/undo flow; an unconfirmed trial is visible on every page with a link to
keep or restore it. No advanced topology expander or local addressing/sharing form
is exposed in Hardware. Disconnected views show unavailable instead of stale actions.
Opening a page never starts scans, route changes, bus traffic or other I/O.

## SSH keys

Paste one OpenSSH public key (Ed25519, RSA or ECDSA), never a private key. Keys
are identified by SHA256 fingerprint, so duplicates are ignored; the device stores
up to 32. Removal needs confirmation and blocks only **new** logins. Removing the
last key leaves USB password access. Incoming observations never overwrite a draft.
See [recovery access](networking.md#local-recovery-and-http-exposure).

## Hardware and application ownership

The standard UI configures gateway interfaces, not connected equipment. Equipment
names, Modbus units/registers, S7 endpoints and polling belong to applications.
There is no equipment-label editor or Modbus register form in Hardware. The
existing network-observation and diagnostic APIs remain available independently.

Ethernet addressing, routes and bridging remain Network-owned. An enabled application
port starts without IPv4, DHCP, DNS, a default route or bridge. Apps request isolated
local addressing through a process-owned SDK claim; active or unresolved claims block
platform network changes. Disabled independent ports are explicitly held down.
Saved legacy joined/equipment configurations are rejected and retained for explicitly
authorized administrator migration, never silently converted or erased.
The optional [Tailnet subnet-router plugin](../plugins/tailnet_subrouter/README.md)
provides explicit local configuration and advertisement, disabled on every startup. RS485 claims are
exclusive and exclude diagnostics; CAN receive subscriptions may be shared.
Active claims/subscription counts are public observations, never PIDs or opaque
handles. CAN reconfiguration is rejected while applications subscribe; UI-disabled
controls are not the backend interlock. The current UI reports resource use, not
which installed app owns a caller. EM300/extension-card enumeration is not implemented.

Equipment label/scan/share commands are removed. A passive neighbor-cache read model
belongs to applications, not a platform compatibility API. Hardware has no neighbor
inventory, labels, scan or sharing controls.
The first application network API supports one isolated Ethernet claim per gateway.

## Controls

- **Color theme:** the header icon opens System / Light / Dark choices. The
  preference stays in the browser and follows other tabs. Switching works even
  while LiveView is disconnected or browser storage is unavailable. Theme code
  is bundled in the external JavaScript asset; firmware keeps its strict CSP.
- **Subnet routing:** configure and explicitly enable the optional starter app.
  Advertisement does not prove tailnet approval or reachability; unknown is not Off.
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
Runtime cookies are read only on an explicit reveal in Remote access, retained
only in that requesting view, and cleared on hide, node change or device loss.
Cookie display, like SIM controls, is available over trusted management interfaces,
not restricted to USB. QEMU reports EC100 peripherals as unavailable. The UI has no sign-in; see
[HTTP exposure](networking.md#local-recovery-and-http-exposure).

## Developer workbench

`mix dev` serves `lib/workbench_web/` at localhost:4000:

| Page | Route | Purpose |
| --- | --- | --- |
| Home | `/` | Resume applications/runs, current operation and actionable bench problems |
| Devices | `/devices` | Physical gateways and owned QEMU devices, with filters |
| Physical device | `/devices/physical/:address` | Overview, read-only SSH checks, USB-only disruptive tests and reviewed device procedures |
| Simulated device | `/devices/:id` | Read-only observations, gateway link and diagnostic fault/wiring state |
| Develop → Applications | `/develop`, `/develop/applications`, `/develop/applications/:id` | Create/open SDK projects; QEMU install/run; reviewed physical install leaving apps stopped |
| Develop → Firmware | `/develop/firmware` | Build, owned QEMU Start/Stop/Reset and wiring, test/debug device selection, results and action log in one workspace |
| Firmware → Scenarios | `/develop/firmware/scenarios/:id` | Confirm runs and inspect device results; return to the firmware workspace |
| Firmware → Manual debugging | `/develop/firmware/manual/:id` | Explicitly acquire manual control, inject reversible faults, inspect console instructions and release control |
| Provision | `/provision` | Guided initial EC100 USB MASKROM preparation, destructive review and verification |

Physical workspaces separate **Hardware tests** from **Procedures**. Use **Find
USB gateways** to add EC100s found over an existing independent USB management
network. Read-only hardware readiness checks explicitly select Ethernet, 4G or
Ethernet with 4G backup and work over verified SSH on LAN, Tailscale or USB. No
independent USB connection is required. They do not configure the selected
profile, unlock a SIM, interrupt a link or prove failover/failback. The disruptive
assisted failover test still fails closed without independent USB management,
even if LAN/Tailscale works.
The separate **assisted failover test** requires explicit cellular-data and cable
disruption consent. A human disconnects Ethernet when prompted, while the
workbench observes physical link loss and online 4G takeover over USB, then
prompts restoration and verifies Ethernet preference with 4G still ready. Each
phase has a two-minute deadline. Identity, firmware and boot must stay unchanged;
USB loss or a changed trial fails closed. Restore all cables after failure,
cancellation or a lost workbench connection. No automatic cable fixture exists.

**Procedures** links setup/restore to the native gateway Internet, remote-access
and settings editors; the workbench never proxies configuration/PIN commands.
Sanitized diagnostic snapshots work over verified SSH without USB and contain
only public identity/boot and readiness
fields, not raw logs/settings/credentials/SIM identifiers. Reports stay in the
owning workspace for review/copying; no file is uploaded automatically.

**Reboot and verify** reviews identity and the current boot over LAN/Tailscale SSH
or explicitly selected independent USB, requires typed
address confirmation, then arms a three-minute observation window. The operator
uses the physical button once as instructed; there is no remote reboot command.
A different boot ID, the same identity and firmware, validated firmware and healthy
network state must be observed over the reviewed management connection. Remote
management may not return; that leaves verification incomplete, never a retry. Reviews expire after ten
minutes and are consumed once. Observation can be stopped cooperatively after a
bounded read; it cannot undo a physical action or cancel a firmware write.

**SSH update, reboot and verify** is available over LAN/Tailscale without USB and
reuses the firmware review and typed confirmation, then checks a new boot,
identity, version and ready state. Independent USB verification is a separate,
stricter choice that binds SSH to the direct interface. Standard SSH updates also
remain available with manual verification. **Factory reset**
is a deliberate physical-button recovery checklist, not a remote erase button;
full USB MASKROM reprovisioning has its own destructive review. See
[firmware updates](firmware-updates.md) and [button recovery](indicators.md).

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
that workspace's actions, not in a global expander. Application details include
**Install on physical device**: package snapshot and read-only verified SSH review,
then a ten-minute, one-use typed-address confirmation. The new app is installed
stopped/disabled; existing installs are rejected rather than upgraded or started.
Identity/boot/storage are rechecked, hash validation and new-app admission happen
inside the device's Apps owner, and uncertain writes are never automatically retried.
Review/results stay with the application, never a firmware confirmation panel.
QEMU installation keeps its separate owned-device reservations and install/run
behavior. Backend admission is authoritative. See [firmware updates](firmware-updates.md)
and [development](development.md).
