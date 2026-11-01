# Board-driven Ethernet policy

## Goal

Remove EC100-specific Ethernet assumptions from shared firmware. Board config
owns resource facts; Hardware normalizes them; Network owns validation, trials,
leases and persistence. UI and plugins consume those contracts instead of
repeating interface names or branching on the board model.

This is a plan, not authorization to change saved settings, flash a device or
change workstation networking. Remove this file once implemented; `docs/`
describes the current system.

Until EM300's jack mapping is verified, EM300 declares `eth0` and `eth1` as
both `assignable: true` and `network_roles: [:internet]`, matching today's
behaviour. Restrictions are added only after verification.

## Hardware facts and qualification gate

- EC100 has two Ethernet resources. Preserve its currently supported ability to
  choose either for Internet and assign the other to a plugin.
- EM300 has three physical Ethernet jacks, specified as one WAN and two LAN.
  Stock Linux exposes only `eth0` and `eth1`.
- A switch connecting both LAN jacks to one interface is the leading hypothesis,
  not a verified fact. Neither the WAN mapping nor independent per-jack status
  is established. Do not create a fictional `eth2`.
- EM300 has no exposed CAN ports. Source corrections remove those resources and
  disable the CAN device-tree nodes; the running device has not received those
  corrections yet.

Before enabling EM300-specific WAN restrictions, verify the jack/interface
mapping and shared-LAN topology from authoritative board information, read-only
inspection, or a separately authorized physical test. If verification remains
blocked, complete the generic work but leave the physical mapping unqualified;
do not guess a WAN interface or silently change existing connectivity.

## Intended model

One Ethernet resource represents one independently configurable Linux network
interface, not necessarily one physical jack.

Keep plugin ownership and Network capabilities independent:

- `assignable: true` means plugins may own the resource.
- `network_roles: [:internet]` means Network may use it as an Internet uplink.
- `network_roles: []` means it cannot be an Internet uplink; this does not
  prevent an assigned plugin from using Network's checked local-link APIs.
- Do not add `:plugin` to `network_roles`: that would duplicate `assignable`.

Both EC100 Ethernet resources have `assignable: true` and
`network_roles: [:internet]`. Network still excludes the current Internet
resource from plugin assignment and checks reservations at admission.

After EM300 mapping is verified, its two resources are described as:

```elixir
# WAN-facing resource (ID deliberately unspecified until qualification)
%{id: "...", kind: :ethernet, assignable: false, network_roles: [:internet]}

# Shared LAN resource, if the switch topology is confirmed
%{
  id: "...",
  kind: :ethernet,
  assignable: true,
  network_roles: [],
  jacks: ["LAN 1", "LAN 2"]
}
```

These fragments omit board labels for brevity. Keep connector information
purely descriptive; `jacks` is not another resource list or permission source.
Do not introduce a switch-management abstraction or synthetic per-jack resources.

After qualification:

| Board resource | Internet commissioning | Plugin assignment |
| --- | --- | --- |
| EC100 Ethernet resource A | Allowed | Allowed when not Internet-owned |
| EC100 Ethernet resource B | Allowed | Allowed when not Internet-owned |
| EM300 WAN-facing resource | Only Ethernet uplink candidate | Not allowed |
| EM300 shared LAN resource | Not allowed | One assignment for both LAN jacks |

At most one Ethernet resource can hold the Internet role. Cellular and backup
rules remain Network-owned. No new cellular capability is implied for EM300.

## WLAN capability

Among the currently supported boards, only EM300 supports WLAN. This is another
board capability, not an Ethernet special case or a board-name check in the UI.

The supplied radio inspection establishes one physical radio (`phy0`) and one
current netdev (`wlan0`), with no `phy1` or current `wlan1`. The driver reports
support for virtual interfaces: up to one managed, one AP, one P2P client/GO and
one P2P device, with at most four total. These advertised limits do not qualify
station/AP operation or guarantee arbitrary simultaneous channel combinations.

Declare one EM300 board resource (with a board label in the full declaration):

```elixir
%{id: "wifi0", kind: :wlan, assignable: false}
```

Board resource kinds are not SDK claim kinds. SDK `Hardware.kinds/0` stays the
list of plugin-claimable kinds; `:wlan` is not added there and `wifi0` is not
exposed through SDK candidates/resources. Radio presence uses one board-declared
sysfs path, not a general identity mechanism.

- EC100 and x86_64 declare no WLAN resource. Declaration means supported;
  Hardware observes radio presence to report availability independently. Do not
  require a WLAN netdev, association or Internet connectivity to report presence.
- Resolve `wifi0` to its physical radio using a checked hardware identity/path.
  The current observation is `phy0`; do not treat a kernel enumeration index as
  a permanent hardware identity or infer radio count from netdev count. Keep
  board-specific identity facts in board data, not in shared polling code.
- Never declare `wlan0`/`wlan1` as board resources or independently assignable
  hardware. Future callers address `wifi0`; Network owns the mapping from that
  logical resource to runtime station/AP/P2P netdevs and their lifecycle.
- Keep WLAN separate from Ethernet resource enumeration. Do not apply Ethernet
  configuration or plugin local-link operations to a radio.
- Keep `assignable` exclusively about plugin ownership; this radio is not
  plugin-assignable. Do not add usable Internet eligibility or commissioning
  controls until Wi-Fi station configuration and admission exist.
- Include board capability declaration, inventory visibility and unsupported vs
  unavailable UI states in this refactor. Preserve existing radio behavior: no
  automatic scans, associations, AP startup or saved-credential changes.
- Wi-Fi station/AP commands, credentials and radio concurrency are a subsequent
  Network-owned implementation using its existing serialized admission, trials
  and cleanup. A declared hardware capability is not a claim that these product
  features already exist.

## Implementation sequence

Commit separately, in this order:

1. Board data, inventory and validation; no behaviour change.
2. Network generalization; EC100 behaves exactly as before.
3. EM300 WAN/shared-LAN policy, only after verified mapping.
4. WLAN capability visibility.

### 1. Declare policy once

- Add allowed Ethernet roles and explicit WLAN capability declarations to
  `firmware/config/{ec100,em300,x86_64}.exs`. Preserve QEMU management isolation
  and EC100 behavior; do not add speculative Wi-Fi ownership abstractions.
- Normalize the additional metadata in `NervesGate.Hardware`; expose narrow
  queries there only when needed. Do not create another cached inventory,
  board-policy facade or mirrored interface list.
- Validate board declarations: unique IDs, boolean assignability, supported
  Network roles and well-formed optional jack labels. Treat `assignable` and
  `network_roles` as independent capabilities, not two copies of ownership.
- Keep presence separate from declared capability. An absent interface remains
  declared but cannot be used for a new assignment or lease.

### 2. Make Network consume resource policy

- Replace fixed `eth0`/`eth1` assumptions in `Config`, `Network.Policy`,
  `Network.Local`, `Network.Subnet`, `Network.Vintage` and `Network.LAN`.
- Pass declared policy explicitly into pure validation; do not make pure Config
  validation depend on a running GenServer or transient interface presence.
- Validate actual presence and availability at admission, including plugin
  assignment, uplink eligibility, joined state and subnet conflicts.
- Generate observations, configurations and interface operations from the
  declared Ethernet resources. Never enumerate all host interfaces as authority.
- Remove the SDK Network API's fixed interface-name guard. The SDK validates
  argument shape; Network validates board policy and caller ownership.
- Preserve one serialized Network worker, deadlines, rollback trials, lease
  ownership, assignment reservations and durable uncertain-cleanup blocking.
- Keep USB recovery and QEMU management outside configurable Ethernet resources.
  Keep `br0`'s existing metadata role; do not add a software bridge between WAN
  and LAN or mistake the metadata carrier for a physical switch.

### 3. Handle persistence without migration

- Keep the existing settings shape (`"mode" => "ports"` with entries keyed by
  interface ID). Validate its keys against the board's declared Ethernet
  resources instead of the fixed `eth0`/`eth1` pair, so deployed EC100 settings
  stay valid with no migration or reset.
- Structurally validate saved data, then validate network roles against this
  board before applying saved configuration, including VintageNet startup paths.
- Accept existing settings only when they satisfy the current contract and board
  policy. Unsupported shapes or incompatible roles fail closed with a specific
  recovery explanation. Do not reinterpret, rewrite, erase or reset them.
- Retain unknown hardware assignment IDs as intent. They grant no access and
  cannot bypass activation validation.
- Require a separately authorized, checked settings change for any incompatible
  live configuration. Preserve recovery access and never silently reassign WAN.

### 4. Simplify commissioning and Hardware UI

- Build the Internet picker from uplink-capable resources. On qualified EM300,
  offer only WAN; on EC100, preserve both eligible choices.
- Build plugin assignment choices from assignable resources and Network's
  current reservation state. Backend checks remain authoritative.
- Show the qualified EM300 LAN resource as one shared group serving two jacks.
  Explain that addressing and assignment affect both, and interface link status
  does not provide independent per-jack status.
- Use board labels and `/hardware/:id` everywhere. Remove positional assumptions
  from forms, summaries, validation messages and plugin selectors.
- Keep drafts separate from subscribed projections; reconnect and reread after
  projection loss. Do not introduce a remote command proxy in Workbench.

### 5. Remove remaining assumptions and validate

- Update scenarios, SDK contract tests, firmware unit/web tests and documentation.
  Derive downstream observation and scenario-helper expectations from declared
  resources rather than substituting another fixed interface list.
- Test capability independence: Internet-only, plugin-only, both and neither;
  plugin local-link admission must not require an Internet capability.
- Test EM300's single `wifi0` resource, supported-but-unavailable radio state,
  and omission of WLAN controls on unsupported boards. Zero, one or multiple
  virtual WLAN netdevs on the same radio must not alter the resource count or
  grant plugin access. Ethernet iteration must never include WLAN resources.
- Presence tests observe the physical radio, not association or netdev names;
  UI wording must not confuse available hardware with implemented Wi-Fi setup.
- Cover zero/one/three Ethernet resource declarations and nonstandard IDs to
  prevent another implicit two-port contract.
- Test EC100 behavior, EM300 policy, reserved/absent resources, stale saved IDs,
  incompatible saved settings, caller-owned leases and whole-plugin cleanup.
- Verify commissioning offers only allowed uplinks, and shared LAN jacks never
  appear as independently assignable resources.
- Extend real QEMU scenarios for supported topology and admission behavior. Host
  tests cannot qualify the EM300's physical switch or jack mapping.
- Run root `mix check`, the EM300 system tests and `git diff --check`. Rebuild the
  EM300 system artifact for the CAN device-tree change, then firmware and assets;
  do not reuse the pre-correction system artifact.
- Report source checks, artifacts and runtime qualification separately. Deploy
  only with explicit authorization; verify reboot health, observed inventory,
  saved-state preservation and commissioning after deployment.

## Completion criteria

- Shared code has no EC100-specific Ethernet list or board-name branches.
- Board config is the only hardware/capability description; Network is the only
  authority for network effects and admission.
- EM300 physical labels and WAN restrictions are backed by verified mapping.
- EC100 behavior and QEMU recovery isolation remain intact.
- Unsupported saved settings are preserved and rejected, never migrated.
- No switch VLAN configuration, per-jack telemetry, automatic plugin activation
  or expansion-card discovery is added in this change.
