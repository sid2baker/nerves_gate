# Remaining board-network capability work

This plan is not authorization to flash devices, change saved settings, associate
Wi-Fi, configure switches or change workstation networking. Remove it when the
remaining capability work is implemented; `docs/` describes the current system.

## Implemented foundation

- Interface IDs and labels come from board Ethernet resources. Network config,
  validation, commissioning, local claims, SDK and Workbench have no fixed
  two-interface list. QEMU management and USB recovery remain separate.
- Factory settings use a board-declared `internet_port` when present (EM300:
  `eth0`); EC100/QEMU run DHCP on their declared Ethernet resources initially.
- Network owns one atomic schema-1 intent record. VintageNet persistence and the
  metadata bridge are removed. Old per-interface files are preserved and rejected,
  never migrated or erased. Saved intent must match current board interface IDs.
- EM300 CAN device-tree nodes are disabled and verified on hardware. EM300 WAN
  is `eth0` according to the vendor's saved `wan.network`; the vendor bridges
  `eth1` for LAN. WAN/LAN labels reflect that evidence.

## Remaining Ethernet capability policy

One resource is one configurable Linux interface, not one physical jack. EM300
has three specified jacks but only two Linux Ethernet interfaces. The shared-switch
layout and independent per-jack telemetry remain electrically unqualified. Do not
invent `eth2`, switch-management APIs or independently assignable LAN jacks.

Keep capabilities independent, declared once in board data:

- `assignable` governs plugin ownership.
- `network_roles: [:internet]` permits an Internet uplink; `[]` forbids it without
  forbidding assigned-plugin local-link claims. Never put `:plugin` in this list.
- Optional `jacks` is descriptive only, never an authority or a second inventory.
- `internet_port` is the factory preference, not an eligibility grant. Validate it
  against an Ethernet resource permitted to serve Internet.

Implement in this order:

1. Add and validate resource metadata; expose it through the existing inventory.
   Preserve EC100/QEMU's ability to choose either Ethernet resource.
2. Make Network the sole capability-admission authority, including saved intent,
   trials, assignment reservations, presence and local claims. Keep pure checks
   explicit and independent of transient interface presence.
3. Generate commissioning from permitted uplinks and Hardware choices from
   assignability; backend validation remains authoritative. Apply EM300-specific
   WAN/nonassignable and shared-LAN restrictions only after checked board evidence.
   Never silently change a live assignment or saved network profile.
4. Cover Internet-only, plugin-only, both and neither capabilities, absent ports,
   stale intent and whole-plugin cleanup. Extend real QEMU scenarios rather than
   creating fake SDK backends. Source tests do not qualify physical wiring.

## WLAN inventory, not Wi-Fi commissioning

EM300's AIC hardware advertises one radio and virtual station/AP/P2P interfaces.
Enumeration and scan success do not qualify association, AP operation or radio
concurrency. EC100 and owned QEMU declare no WLAN capability.

- Declare one board resource `wifi0`, kind `:wlan`, not plugin-assignable. Board
  resource kinds and SDK claim kinds are different; do not add WLAN to SDK kinds.
- Identify presence using a verified board sysfs hardware path, not a hard-coded
  `phy0` index, interface count, association or Internet connectivity.
- Show supported vs absent hardware in inventory. Do not expose unsupported
  controls or imply implemented Wi-Fi commissioning.
- Network owns future runtime station/AP/P2P netdevs and their serialized effects.
  Never declare `wlan0`/`wlan1` as independently assignable resources.
- Test zero/one/multiple virtual netdevs without changing logical radio count.
  No automatic scans, associations, AP startup or saved-credential changes.

Run root `mix check` and `git diff --check`. Report source checks, rebuilt artifacts,
QEMU scenarios and physical qualification separately; deployment is separately
authorized. Preserve all unsupported saved state for explicit recovery.
