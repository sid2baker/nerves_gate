# Hardware qualification and remaining capability work

EC100 and EM300 share the [platform contract](docs/architecture.md#shared-platform-contract):
easy commissioning, remote access, hardware inventory and plugin extensions.
They do not need matching peripherals or storage layouts. Owned QEMU tests the
shared software contracts, not electrical behavior.

This is a remaining-work checklist, not permission to operate hardware. Device
flashing, saved-setting changes, workstation networking, connected-equipment tests
and publication require explicit authorization. Never infer permission from a plan.
Remove this file when the remaining work is complete; `docs/` describes the current
system, and board configs remain the source of hardware declarations.

## Current foundation

- Both physical targets use the same firmware services, UI, SDK, assignment and I/O
  contracts. Board config supplies resources, factory networking and hardware profiles.
- EM300 has booted Nerves, passed initial provisioning/readback and a healthy OTA
  update, and retained plugin-storage data across reboot. This is not rollback or
  full peripheral qualification.
- Ethernet IDs and labels are board-driven. Network owns one atomic settings record;
  obsolete VintageNet files are preserved and rejected, not migrated or erased.
- EM300's expansion bus is a plugin-assignable resource. It is not an implemented
  expansion-card driver or a set of automatically discovered core I/O channels.

Private bring-up evidence remains under ignored `_build/em300-evidence/`; original
NAND backups remain outside the repository. Do not delete them during cleanup or
copy device identifiers, credentials or raw captures into tracked documentation.

## Shared-baseline acceptance gates

Qualify EC100 and EM300 against the same source revision, using each board's own
firmware/system artifact. Board-specific defaults, recovery links and storage engines
are expected; hidden shell fixes, borrowed board profiles and dummy resources are not.
Use the supported UI/administrative workflows, on isolated hardware and with explicit
authorization for every state-changing test. Do not reset a working bench to create
a fresh-device fixture.

| Gate | Test | Pass condition |
| --- | --- | --- |
| B1 · Commissioning | On an authorized fresh/reprovisioned unit, use local access to commission the board's supported Ethernet Internet connection. Verify the resulting address, route and connectivity. | Factory defaults and normal commissioning work without manual configuration repair; confirmation is explicit and independent recovery access remains usable. |
| B2 · Remote access | Enroll Tailscale explicitly, check granted `tag:nerves-gate`, authorize an SSH public key and reconnect from an authorized remote host. | Workbench lists the device once, remote identity/health are readable, verified SSH succeeds, and an unauthorized key fails. No credentials are exposed through discovery or projections. |
| B3 · Hardware truth | Inspect inventory and assignment choices before opening any equipment connection. Compare them with board declarations and observed hardware. | Supported, absent, reserved and assigned states are distinguishable. Internet/recovery resources cannot be taken by a plugin, and unsupported hardware has no misleading usable controls. Connector count is not treated as interface count. |
| B4 · Plugin lifecycle | Prepare supported plugin storage, explicitly select/start a real plugin, assign an isolated eligible resource, use it, stop it and release it. Exercise checked reassignment with the appropriate real plugin. | The SDK and I/O contracts work on both boards. Saving/assignment does not open equipment connections; access requires permission and an explicit command. Stop/release closes handles, withdraws owned routes and permits checked reuse. Uncertain cleanup blocks reuse. |
| B5 · Persistence | After confirmed changes, reboot through an authorized workflow; repeat the checks after a successful reviewed update. | Confirmed network intent, Tailscale identity, SSH keys, plugin configuration and hardware assignments survive. Documented volatile leases/connections are not silently replayed; discovery does not activate plugins. |
| B6 · Recovery and rollback | Separately test an unconfirmed network trial, a failed settings write, and authorized A/B update failure/rollback on a recoverable fixture. Include an interrupted update with a defined safe fault point and original backups available. | Network rollback retains confirmed intent. Unknown persistence/maintenance outcomes block further writes. The device returns to a known healthy firmware slot with usable recovery access and preserved settings; no blind retries, automatic resets or erased state. |

B4 verifies shared infrastructure with a usable resource, not every peripheral on
each board. B6 fault injection needs its own reviewed procedure; this table does
not authorize arbitrary power cuts or NAND writes. Extend existing scenarios where
they apply; assisted physical observations remain explicit evidence, not mocked
hardware or a fake SDK backend.

## Baseline blockers versus optional capabilities

A board is baseline-ready only when B1–B6 pass on the recorded candidate. An
untested gate blocks a readiness claim just as a failed gate does. Equal service
configuration and passing host/QEMU tests do not substitute for physical evidence.

Baseline blockers include broken commissioning, remote access, recovery, plugin
storage/access/cleanup, lost persistent state, misleading inventory and unsafe
update/rollback behavior. In particular, verify EC100's plugin-storage slot and
plan an explicitly authorized settings-store cutover before deploying to devices
with obsolete persisted files. Acceptance does not authorize their migration/reset.

The sections below track additional capability work, not automatic baseline
requirements: restricted Ethernet roles (only if verified requirements need them),
WLAN inventory/commissioning, Bluetooth, cellular, expansion protocols and individual
field-peripheral qualification. They must remain explicitly unsupported/unqualified
until implemented and tested. They become blockers if enabled or advertised as
usable in the candidate, if they break the shared baseline, or if explicitly selected
as a product requirement. Watchdog/reset behavior that can affect boot or recovery
must be qualified regardless of whether a user-facing control is offered.

Release readiness is separate from baseline readiness: locked builds, routine CI,
exact-commit QEMU integration, system artifacts and authorized publication still
have their own gates. Optional hardware features need not match between boards.

## Per-board evidence and decision

The matrix below has no results for a shared-baseline candidate yet. Earlier EM300
bring-up observations above are historical evidence, not passes for current firmware.
Use only `passed`, `failed` or `untested`; record blockers separately. Do not mark a
shared-baseline gate not-applicable to make a board pass.

| Gate | EC100 | EM300 |
| --- | --- | --- |
| B1 · Commissioning | untested | untested |
| B2 · Remote access | untested | untested |
| B3 · Hardware truth | untested | untested |
| B4 · Plugin lifecycle | untested | untested |
| B5 · Persistence | untested | untested |
| B6 · Recovery and rollback | untested | untested |

For each board's result record:

- **Candidate:** full firmware source revision (including dirty state, if any),
  firmware version/archive SHA-256, system version/fingerprint and selected plugin
  versions. Final acceptance requires a clean, reproducible candidate; source changes
  invalidate affected gates and must be evaluated before reusing other evidence.
- **Execution:** date, gate, supported procedure/scenario and sanitized evidence
  reference. Separate host checks, built artifacts, QEMU results and physical results.
- **Decision:** result, observed versus expected outcome, remaining blocker and the
  next authorized action. An accepted job, timeout or lost observation is not a pass;
  inspect uncertain outcomes rather than repeating effects.

Keep raw evidence private and outside the repository. Tracked results must not
contain serials/MACs, SIM identifiers, addresses identifying a device, login URLs,
cookies, CSRF tokens, PINs/PAP credentials, private keys or identity disks. Record
only non-identifying board/candidate facts and sanitized conclusions here. Before
removing this plan, preserve final sanitized qualification results with the current
hardware documentation; unresolved blockers must not disappear during cleanup.

## Prepared physical qualification procedure

### Read-only preparation snapshot

- The restarted Workbench matches the checkout's protocol/SDK inputs; maintenance
  admission is idle. Only EM300 is currently listed as a connected physical gateway;
  EC100 availability is not established.
- EM300 reports firmware source revision
  `b599ae8ec024d0766d8c5335c05d193e5fc7e774`, not the newer board-label/settings-store
  changes. Do not treat observations from that image as qualification of current code.
- Internet and enrolled Tailscale are online, the required tag is granted, plugin
  storage reports ready, and both bundled plugins are stopped and disabled.
- Read-only investigation resolved the apparent readiness discrepancy: projected
  `network.ready` is trial-confirmation readiness and is false without a trial.
  `System.hardware_info/0` and `Network.ready?/2` both report configured topology
  ready, with no conflicts; the official `hardware_readiness` scenario passed.
  No topology repair or settings rewrite was needed.
- USB reports no link. Independent recovery has not been demonstrated for this
  session; do not interrupt the sole working management path.
- Subsequent authorized exploratory tests are recorded below. No gateway network,
  enrollment or SSH-key changes, successful hardware-assignment changes, equipment
  connections, reboot or firmware upload were performed. One temporary plugin
  definition was saved, restored across plugin restart, then deleted. The candidate
  acceptance matrix remains untested.

These are preliminary observations, not acceptance results or guarantees that the
bench remains idle. Recheck session identity, device identity and admission before
any later operation; do not copy private identifiers into this plan.

### Exploratory live results (older EM300 firmware)

Observed 2026-11-01 UTC. These results apply only to the older revision above, not a
clean candidate containing the current changes. No EC100 is connected, so EC100
acceptance is blocked on a fixture. The installed plugins tested were Modbus 0.4.3
and Tailnet subnet-router 0.1.10; no plugin artifact was replaced.

| Area | Result | Boundary / remaining work |
| --- | --- | --- |
| Configured topology | passed: official `hardware_readiness` scenario, validated firmware, no network conflicts | Does not prove fresh commissioning or new settings-store compatibility. |
| Existing remote access | passed: official `physical_remote_access` scenario; authenticated online Tailscale with required tag, pinned SSH with existing key, specific authentication rejection for an ephemeral unregistered key | No logout/re-enrollment, key mutation or recovery-path test was performed. Transport errors do not count as authentication rejection. |
| Hardware observations/admission | declared Ethernet, RS485 and expansion resources reported present; nonexistent-port review rejected; Internet-port confirmation rejected with `hardware_reserved`, assignments unchanged | No electrical qualification or successful physical-port assignment. Review creation alone does not grant ownership; final admission correctly rejected the protected uplink. |
| Modbus plugin lifecycle/storage | passed: start restored zero connections with healthy storage, managed SDK candidates query succeeded; one temporary stopped loopback-client definition survived plugin restart, was deleted, and checked stop completed | No transport start, field traffic or I/O writes. No existing definition was modified; an empty configuration record remains after probe deletion. Resource assignment/reuse, real loopback I/O and device-reboot persistence remain untested. |
| Subnet-router lifecycle | passed: start remained disabled with no local claim/routes; checked stop completed | No addressing, route advertisement or sharing was enabled. |
| Post-test state | both bundled plugins stopped/disabled, assignments unchanged, Internet/remote access online and storage ready | No uncertain command outcome was observed. |
| Persistence / fault recovery | untested on the current candidate | No reboot, failed-write injection, rollback, power interruption or destructive provisioning without an independent recovery path and bounded procedure. |

The repeatable `physical_remote_access` case was added to the existing physical
catalogue, not to the QEMU catalogue. It changes no credentials/settings and opens
no SSH shell. Its host test ensures unsupported fixtures skip before access; its
live execution passed through normal Jobs admission.

### Proposed order and permission boundaries

1. **Resolve preflight without changes.** Inspect network readiness and private
   warning logs using supported reads. Establish whether EC100 is available. Have
   the operator provide a working independent USB or serial recovery path and verify
   access before any connectivity test. Connecting cables or changing workstation
   networking needs its own approval. Do not force a failing readiness scenario
   through maintenance admission or bypass a blocked/unknown job.
2. **Fix the candidate.** Finish reviewing the local source changes, choose a clean
   revision and build each board's firmware/system artifacts. Record their hashes.
   Source review/build is distinct from permission to commit, push or upload.
   Inspect existing persisted settings before preparing the new-store cutover. Any
   required external reprovisioning is a separate destructive operation, not an
   automatic part of an update or acceptance test.
3. **Review deployment separately.** For each available physical board, use
   Workbench's firmware review and single-use confirmation, including immutable
   plugin compatibility and pinned SSH trust. Request explicit authorization for
   that image and target. After acceptance, wait for the exact new revision and
   healthy validated boot; uncertain outcomes stop the procedure. Do not proceed
   merely because an upload was accepted.
4. **Run B1–B3 on an authorized fixture.** Fresh commissioning requires explicit
   permission to provision/reset a disposable fixture; preserve the existing bench.
   Enrollment and SSH-key addition/removal need separate operator approval. Do not
   log out a working remote session or remove the last usable key to manufacture a
   fresh state. Read-only inventory inspection does not qualify physical buses.
5. **Run B4–B5 with a bounded effect scope.** Identify an isolated resource and real
   plugin, then review assignment/start/use/stop/release and the affected whole-plugin
   stop scope. Request permission for those actions, persistent setting changes and
   reboot. Do not drive connected field equipment, auto-enable sharing or join the
   EM300 LAN jacks together. Verify cleanup before reuse and compare confirmed
   settings after reboot and the separately reviewed successful update.
6. **Run B6 only under a specific fault procedure.** First agree the fixture, exact
   fault point, abort conditions, backup and recovery method. Obtain authorization
   for network interruption, failed-write injection and update/rollback testing
   separately. Start with applicable owned-QEMU scenarios when explicitly authorized;
   they do not prove physical NAND/eMMC recovery. No arbitrary power cuts, bootloader
   writes, resets or uncertain-operation retries are implied.

Do not execute QEMU-only plugin/storage/reboot scenarios on physical boards by
bypassing their requirements. The physical `hardware_readiness` scenario is read-only,
while `hardware_backup` and `button_reboot` require assisted disruption and additional
permissions. They are currently unsuitable for EM300's disabled cellular/front-key
profiles; do not enable those profiles merely to run a scenario. None completes all
baseline gates. A failed Jobs scenario can block
further maintenance, so inspect readiness before submitting it. Stop at every
unavailable requirement or uncertain result and update the per-board evidence rather
than substituting a fallback or widening the test's scope.

## Ethernet capabilities and topology

- Vendor configuration identifies EM300's WAN/LAN interfaces. Confirm the physical
  jack mapping and shared-LAN switch behavior before imposing additional restrictions.
  Never invent a third interface or per-jack resources from connector count.
- Keep factory preference distinct from eligibility. If verified board requirements
  need restricted uplinks, declare `network_roles` in board data; keep it independent
  of plugin `assignable` permission. Optional `jacks` labels are descriptive only.
- Enforce any introduced capability policy in Network's saved-intent validation,
  trials, reservations and admission; derive UI choices from the same facts. Plugin
  local-link access must not require Internet eligibility.
- Preserve EC100/QEMU's supported uplink choices. Do not silently rewrite a deployed
  profile or assignment to enforce a new board policy.
- Cover Internet-only, plugin-only, both and neither permissions, unavailable resources,
  stale saved IDs and checked whole-plugin cleanup. Extend real QEMU scenarios;
  host tests do not qualify physical wiring.

## WLAN inventory and qualification

- EM300 radio detection and scanning have been observed; station association, AP
  operation and concurrency are not qualified. These are not commissioning features.
- Add one logical board resource `wifi0`, kind `:wlan`, not plugin-assignable, using a
  verified board hardware path for presence rather than a kernel `phy0` index.
- Keep WLAN out of SDK claim kinds and Ethernet iteration. Virtual netdevs must not
  change logical radio count. Expose supported/absent states without suggesting
  working Wi-Fi setup; do not invent radio resources on unsupported boards.
- Future station/AP/P2P configuration belongs to Network's serialized admission,
  trials and cleanup. No automatic scans, association, AP startup or credential changes.

## Expansion plugin

- One supervised plugin owns the assigned expansion resource, UART and reset/link
  lines. Core provides checked ownership and I/O contracts, not the device protocol.
- Implement discovery, cyclic input and echo-confirmed output through existing SDK
  and I/O APIs. Never blindly replay uncertain output writes or auto-activate modules.
- Qualify digital input encoding with authorized stimulus; analog formats and
  configuration bytes remain unresolved. Opening a page must not operate equipment.

## Physical and deployment checks

- Qualify EM300 RS485 electrical/direction behavior, modem, Bluetooth, watchdog timing,
  front LEDs/button and any exposed GPIO semantics before enabling their profiles.
  EC100 settings are not evidence that EM300 peripherals behave identically.
- Verify EC100's declared plugin-storage slot on hardware. Preserve supported EC100
  behavior while testing EM300; unsupported capabilities should fail explicitly.
- Exercise A/B rollback and failure recovery, not only a successful update. Preserve
  original backups and recovery access; never bypass uncertain maintenance admission.
- Rebuild and validate firmware after runtime changes. The new network-settings store
  requires a separately authorized cutover for devices with old persisted files;
  no automatic import, erasure or reset is allowed.
- Check routine CI and exact-commit QEMU integration separately. EM300 system release
  preparation, automatic publication wiring and actual publication are separate work;
  local builds and a development version are not release qualification.

Before completion run root `mix check` and `git diff --check`. Report source checks,
artifacts, QEMU scenarios, physical tests and CI results separately. Never describe
an accepted operation, a passing host test or a detected peripheral as qualification.
