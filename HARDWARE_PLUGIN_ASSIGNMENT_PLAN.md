# Hardware assignments for trusted plugins

## Status and objective

Source implementation now includes exclusive assignments in the existing plugin
manager, current-only hardware intent persistence, assignment-only Hardware UI,
caller-derived SDK resource queries and checked stop-before-reassignment. Built-in
capture/Modbus diagnostics and old SDK bus transport proxies are removed.

The requested RTU extension is implemented in Modbus plugin 0.2.2 using yamodbus
and the firmware's existing circuits_uart 1.7.0. Packages remain pure BEAM; the
native UART driver stays platform-provided. Host tests use disposable PTYs and real
transport code. QEMU fault qualification, actual EC100 RS485 electrical behavior
and physical handoff qualification remain pending. The schema-11 firmware with
Modbus 0.2.1 and subnet-router 0.1.2 was deployed to the EC100 with healthy boot,
Hardware inventory and plugin management verified. Saved selections are preserved;
new bundle versions require explicit selection. The subsequent Modbus 0.2.2
worker-monitor race fix is host-tested and built, not deployed. No physical
equipment traffic, port reassignment or saved metadata migration was performed.

Validation: `mix check` passed (13 SDK, 139 firmware, 177 root, 9 subnet-router,
11 Modbus tests, plus 3 generated-project tests). The 11-test Modbus suite passed
20 repeated runs using supervised MuonTrap PTY bridges, with no surviving test
bridges. x86_64 dev and EC100 dev firmware builds passed. Archive inspection verified
Modbus 0.2.2 bundles only its main application and yamodbus, declares serial capability
and pins platform circuits_uart 1.7.0 without loading plugin code into the host.

Simplify Hardware into inventory, operator permission and exclusive assignment.
Plugins open and supervise their assigned hardware using ordinary libraries.
Remove platform-owned capture/protocol diagnostics instead of preserving them as
legacy paths. Reuse `NervesGate.Plugins` lifecycle admission; do not build another
manager, generic transport framework or lease/byte-I/O layer.

Initial switching is **stop whole plugin → confirm release → reassign → leave
stopped**. Per-port live handoff is explicitly deferred.

## Ownership model

- A detected exclusive port has zero or one assigned plugin.
- A plugin may have multiple assigned ports and supervise one worker per port.
- Assignment is persistent operator intent, not proof of an open connection or
  equipment readiness. Enabled, assigned, running and actively open are distinct.
- The plugin owns its actual UART/CAN handle and protocol settings/connection workers.
  Firmware does not open a competing handle or parse protocol traffic.
- Firmware owns hardware identity, protected-port policy, assignment validation and
  lifecycle/reassignment admission. Plugins are trusted same-BEAM code; assignment
  is coordination, not OS-level isolation or protection against malicious code.
- TCP clients use normal sockets without assigning an Ethernet interface. Multiple
  Modbus TCP/S7 connections may use the gateway's existing networking concurrently.
- Internet/USB/management resources cannot be assigned away. Subnet-router address
  and Tailscale route operations remain platform-controlled: do not replace their
  existing durable cleanup journal with a simple assignment flag.

## Scope and boundaries

Apply exclusive assignment first to the allowlisted physical serial/RS485 and CAN
ports. Do not offer shared CAN consumers in this first contract. Remove old shared
SDK bus subscriptions/claims when their direct plugin-owned replacements are ready;
no compatibility shims or alternate ownership route.

Expose CAN bitrate/listen-only and serial speed/parity in the owning plugin when
implemented, not as independent platform controls that can race an active owner.
The platform still validates board-supported modes and electrical constraints and
performs any privileged link setup required by its existing driver. Configuration
must have one owner; there must not be both a diagnostic configuration and plugin
configuration for the same port. Never guess RS485 DE/RTS wiring or promise modes
not qualified for the board.

Keep the current pure-BEAM plugin policy. Native drivers/libraries may only come
from explicitly selected, target-built firmware prerequisites, not plugin payloads.

**The operator extended this implementation to include Modbus RTU.** Modbus declares
serial capability and the exact existing platform circuits_uart 1.7.0 dependency;
its archive excludes native payloads. The initial serial profile remains automatic-
direction 9600 8N1, with explicit authorization/no-other-master acknowledgement and
one connection per assigned port. Physical qualification is not implied by PTY tests.
Tailnet subrouter is not a serial/CAN owner. There is no selected CAN plugin; having
no eligible plugin is valid, not a reason to retain built-in diagnostics.

## Minimal contract

1. Add a small, optional declaration of supported hardware kinds to plugin metadata
   (for example serial or CAN). Only declared, firmware-supported kinds are eligible
   assignment targets. This is UI/admission metadata, not a protocol-driver registry.
2. Provide one SDK query for the actual managed caller's assigned, enabled, detected
   resources. Return stable port IDs, hardware kind and allowlisted open parameters
   or device path; never arbitrary operator-supplied filesystem paths. Resolve the
   caller through existing OTP membership/generation ownership.
3. The plugin uses an ordinary supervised worker/library to open each assigned port.
   No opaque claim reference, SDK byte stream or firmware worker proxies its I/O.
4. The resource query reports unavailable/disabled/missing distinctly and does not
   open hardware. A plugin cannot choose someone else's port through this API.
5. Use normal OTP shutdown as the initial cleanup contract. No new mandatory
   `acquire/release/start/stop` callback family. Plugin-specific configuration and
   connection APIs stay inside each plugin.

A plugin must own all transport workers in its application supervision tree and
close handles during shutdown. Libraries that leave detached workers, inherited
handles or unmanaged native processes are not supported without an explicit cleanup
solution. The integration audit must prove this before offering the capability.
A stopped OTP application alone is not sufficient evidence for a library known to
leave external work behind. Existing uncertain/busy cleanup must block reassignment;
never force a handle takeover or rely on a fixed sleep.

## Implementation phases

### 1. Remove diagnostics and define the hardware read model

- Remove `Buses.capture/1`, `modbus_read/2`, their workers/protocol parsers, Hardware
  event handlers/forms/results and diagnostic-only helpers, tests and scenarios.
  Retain only independently needed hardware detection/driver code.
- Inventory all references in `firmware/lib/nerves_gate/buses*`, bus UI components,
  projections, SDK, scenario catalogue and public action/docs. Do not leave aliases,
  unused operations or hidden diagnostic endpoints.
- Hardware shows port identity, physical presence, operator enablement, assignment,
  owning plugin lifecycle state and relevant driver/cleanup errors. No equipment
  discovery, protocol requests or claim/subscriber counters from the removed model.
- Keep hardware availability/status truthful even when no plugin is selected.

**Gate:** loading or interacting with Hardware cannot capture frames or issue Modbus
requests; no obsolete diagnostic command remains callable.

### 2. Implement one assignment owner and durable state

- Keep assignments with the plugin manager, separate from immutable artifact
  identity. Use one bounded current-only metadata format and atomic persistence;
  do not introduce a second coordinator GenServer for cross-domain transactions.
- Key assignments by stable allowlisted hardware IDs and plugin IDs, not PIDs,
  versions, device paths or UI labels. One plugin can own several IDs.
- Validate plugin existence/capability, port existence/support, enablement,
  protected resources and conflicts on the backend. Never accept UI filtering as
  admission. A temporarily absent assigned port retains its assignment, reports
  missing and does not silently transfer to another device/plugin.
- Hardware enable/disable and assignment changes go through the same serialized
  admission boundary as plugin start/stop. Block changes while an affected plugin
  is starting/running/quiescing or an outcome is unresolved.
- Missing plugins after firmware changes retain unresolved intent and report it;
  never redirect their assignments to a different plugin. No automatic migration,
  reset, formatting or erasure of prior metadata. Define and document any breaking
  metadata cutover explicitly before deployment.

**Gate:** duplicate/wrong-kind/protected assignments fail; saved intent survives
restart without opening ports or silently rewriting unavailable selections.

### 3. Direct ownership and checked dynamic reassignment

- A selected eligible plugin queries its assigned resources from its own managed
  process and starts supervised per-port workers explicitly. No Hardware-page
  process opens the handle on its behalf.
- Enforce the initial rule that all affected plugins are stopped before mutation.
  A **Stop and reassign** action is one admitted operation: stop the source and any
  running destination through the existing checked path, confirm cleanup, then
  persist the new assignment. If stopping either fails, do not change assignment.
- If the operator wants to keep other source ports active, explain that the initial
  whole-plugin stop interrupts all its ports. Do not imply per-port continuity.
- Leave plugins stopped after reassignment. Starting and connecting/polling are
  separate explicit operations, as with the existing plugins.
- Persistence failure leaves a known stopped state with an error; unknown commit or
  cleanup outcomes block further changes until inspected. No automatic restart,
  traffic replay, speculative rollback or takeover after timeout.
- Remove superseded SDK CAN/RS485 claim, subscription and transport operations,
  their backend dispatch and platform handle ownership in the same cutover. Retain
  shared membership fencing and Network cleanup where they still have a real job.

**Gate:** one physical port never has two cooperative owners, multiple assigned
ports work under one plugin, and failure cannot make reassignment appear complete.

### 4. Hardware and plugin UI

- Replace capture/protocol controls with enabled/assigned state and an eligible
  plugin selector, including **Unassigned**. Explain why ports/plugins are ineligible.
- Show the impact of whole-plugin stopping and require explicit confirmation before
  stopping/reassignment. Keep operator drafts separate from committed assignment.
- Show missing/disabled/blocked states accurately. Unknown outcomes require explicit
  refresh/inspection; a refresh never retries or cancels writes.
- Plugin pages own per-port protocol configuration and connection controls. Reuse
  existing optional LiveComponent hosting; no hardware-specific plugin UI framework.
- Modbus TCP UI remains a TCP-device configuration page with no physical assignment
  requirement. Tailnet subrouter retains its dedicated application-interface workflow.

**Gate:** UI describes the same ownership/admission rules as the backend and cannot
initiate traffic merely by opening pages or choosing a draft assignment.

### 5. Validate and document the clean cutover

- Unit/component tests cover eligibility, multiple ports per plugin, conflicting
  assignments, missing ports/plugins, protected resources, persistence failures,
  disabled ports, forged requests and unresolved lifecycle operations.
- Extend existing managed QEMU fixtures/scenarios rather than add a hardware-mock
  backend. Exercise real disposable resources where owned QEMU supports them,
  two managed fixture plugins, checked whole-plugin shutdown and reassignment.
- Verify handles/workers actually close before the destination can start. Test
  stop failure, busy cleanup, manager restart, interrupted confirmation and repeated
  reassignment without force-purge or automatic replay.
- Run `mix check`, changed asset builds and relevant target builds. Run focused
  device scenarios only against user-started disposable supervised devices. Report
  unsupported physical/native cases separately rather than inventing qualification.
- Update SDK/public API docs, Hardware help, scenario catalogue and architecture.
  Remove legacy commands and obsolete tests rather than maintaining two models.

**Gate:** host/build results and actual runtime evidence are recorded independently;
no unexecuted hardware scenario is marked passed.

## Deferred

- Per-port live handoff while other workers of a plugin keep running.
- Shared CAN ownership or a generic hardware transport/driver adapter framework.
- Modbus ASCII, additional UART profiles and new native firmware prerequisites.
- Automatic discovery, equipment writes, restoring active equipment connections.
- Physical gateway update or live assignment migration. Those require separately
  reviewed authorization; creating/implementing this plan does not grant it.
