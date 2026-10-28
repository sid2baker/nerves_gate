# Platform I/O and automation implementation plan

## Goal and boundaries

Make automation a first-class Nerves Gate subsystem. Plugins own device protocols
and equipment semantics; the platform owns shared I/O and automation infrastructure.

```text
hardware → plugin → input observation → automation → desired output → plugin → hardware
```

**Inputs describe what we observe. Outputs describe what we want.**

- `NervesGate.IO` owns definitions, live plugin bindings, latest observations,
  subscriptions, exclusive output ownership and live desired values.
- `NervesGate.Automation` owns automation persistence and execution.
- Jido is a candidate internal execution dependency, not part of the public contract.
- LiveFlow is a candidate native gateway editor, not an execution engine.
- Plugins keep protocol connections, reconciliation, retries, readback and physical
  effects in their supervised processes.

Automation is not hard real-time and is not a safety controller.

## Agreed v1 contract

```text
Input  = persisted definition + latest live Observation
Output = persisted definition + live Desired Value
```

An output may reference an ordinary input for feedback. There is no separate
output observation store: a displayed `reported` value is that input's snapshot.

- Outputs are repeatable desired-state setters, not one-time commands. Examples:
  `relay = true`, `setpoint = 22.0`, `speed = 1400`, `mode = "auto"`.
- Idempotence must hold for the equipment operation, not just the API spelling.
  Setting a register that retriggers a pulse is not a supported output.
- Toggle, pulse, increment, dispense and other one-time effects are out of scope.
- Inputs are latest observable state, not reliable event streams. Short-lived
  occurrences and intermediate transitions may be missed.
- Notifications are hints that may be duplicated or coalesced, not silently dropped.
  While the controller and subscriber remain alive, a dirty input eventually causes
  a hint. Consumers read current snapshots rather than treating hints as values.
- Definitions persist; bindings, observations, subscriptions, writer ownership
  and desired values do not. Nothing physical happens merely because I/O restarts.
- Manual and automation writers use the same validation and exclusive ownership.
- Writer loss clears its desired values and releases ownership without an implicit
  device operation. Clearing desire does not undo the device's existing state.
- Reconciliation, retry, shutdown, fallback and watchdog behaviour belong to the
  plugin or equipment, not a platform safe-state protocol.
- Only wall-clock scheduled automation requires synchronized UTC. I/O, manual
  control and state-driven automation use monotonic freshness without that gate.
- No write journals, request state machines, acknowledgements, event history,
  command recovery or cross-component safe-value transactions.
- No models, beliefs, generic engine-adapter framework, distributed execution,
  historical replay or priority-based output arbitration.

If true commands or reliable occurrences are needed later, design distinct
`Command` or `Event` concepts. Do not weaken the meaning of Input or Output, or
include dormant machinery for those future concepts in v1.

## 0. Evaluate Jido and LiveFlow

Before integrating either dependency, verify:

- EC100 and QEMU build compatibility and dependency footprint.
- Compatibility with shared firmware dependencies and locked versions.
- Supervised execution, bounded work and mailbox behaviour.
- Dynamic flow definitions without arbitrary code loading or atom creation.
- Restart behaviour that preserves explicit enablement and reacquisition of outputs,
  rather than restoring executable device work or old desired values.
- Clean separation between flow evaluation and plugin-owned device reconciliation.
- Compatibility with the current Phoenix/LiveView and gateway asset pipeline.
- License, maintenance and release maturity.

Inspect the actual Jido/Runic integration rather than assuming proposed APIs exist.

**Deliverable:** a short use/defer/reject decision for each dependency. The I/O
work can proceed independently of this evaluation. Do not build a temporary rule
engine while waiting for Jido.

## 1. Implement `NervesGate.IO`

The firmware domain, SDK transport wiring, shared data structs and host tests are
implemented. UI, protocol integration and automation remain later phases;
this source implementation has not yet been qualified on a rebuilt guest.

Start with one supervised firmware domain, not separate Registry, LatestValues
and Subscriptions services:

```text
NervesGate.IO
├── definitions
├── live plugin bindings
├── latest observations
├── subscriptions
├── output ownership
└── desired values
```

The controller never performs device operations. It updates in-memory state and
notifies plugin-supervised handlers, remaining responsive during protocol delays.

### Persistence and restart

Persist only validated input and output definitions under `/data`, using the
existing durable file persistence approach. Registration succeeds only after a
new definition has been saved successfully.

- Do not persist PIDs, generation bindings, subscriptions, observations, timestamps,
  writer ownership or desired values.
- Reject unsupported, corrupt or unreadable saved definitions explicitly. Never
  rewrite or erase saved data merely to make it compatible.
- Re-registration must match the saved definition or fail explicitly.
- After an I/O-controller or gateway restart, definitions remain present, bindings
  are unavailable, observations are absent and desired values are nil.
- Plugins register again and publish fresh observations. Writers must reacquire
  outputs and explicitly establish new desired values.
- Registration, rebinding and restoring definitions never establish a desired
  value or initiate a physical write.

No per-output write record or executable recovery work is stored.

### Registration and lifecycle

- Only managed plugin activations may register endpoints in their own namespace.
  Derive membership from the actual caller using Plugins-owned generation bindings.
- Validate output handler membership as well as the registering caller. Both must
  belong to the same activation; the handler remains plugin-supervised.
- Only the live registered input owner may publish its observations. Only the bound
  output handler may read desired values through the plugin handler API.
- Monitor live owners and handlers. Loss of an endpoint owner, output handler or
  activation makes the affected endpoint unavailable and clears its live state.
  For outputs, also release writer ownership and clear desire.
- Old activation processes cannot publish into or read desired values from a new
  activation's bindings. Rebinding does not restore old observations or desires.
- During checked stop, fence new registrations, claims and desired updates. Existing
  plugin processes may read and publish observations while quiescing; plugin-owned
  shutdown runs through its normal lifecycle while protocol processes are alive.
- I/O does not coordinate a shutdown write or wait for device convergence. Existing
  checked plugin resource cleanup remains in force.
- Stable IDs in saved automations remain independent of live PIDs and generations.

### Initial data contracts

The three shared data structs live under `NervesGateSDK.IO`; firmware uses the same
types rather than mirroring another set. Desired state is a typed value or nil,
not a request object. SDK transport operations preserve the actual calling PID.

```elixir
defmodule NervesGateSDK.IO.InputDefinition do
  @enforce_keys [:id, :type]
  defstruct [:id, :type, :unit, :expected_interval_ms]
end

defmodule NervesGateSDK.IO.OutputDefinition do
  @enforce_keys [:id, :type]
  defstruct [:id, :type, :unit, :min, :max, :feedback_input_id]
end

defmodule NervesGateSDK.IO.Observation do
  @enforce_keys [:input_id, :value, :quality, :received_at_ms]
  defstruct [:input_id, :value, :quality, :received_at_ms, :received_at_utc]
end
```

#### Definition fields

- Definition `id` is a plugin-local string, for example `pump.enable`. Accept
  lowercase letter-led segments containing lowercase letters, digits or underscores,
  separated by dots, with a total length of 1–128 bytes. Never convert IDs to atoms.
- Catalogues and saved automations use the full ID, formed from the caller-derived
  plugin name and local ID, such as `modbus_plugin.pump.enable`. Registration returns
  that full ID. Definitions retain their local IDs under their full catalogue keys.
- Inputs and outputs share the plugin namespace. Reject conflicting definitions,
  duplicate live owners and reuse of an input ID for an output. Identical registration
  by the current owner with the same handler is idempotent.
- `type` is exactly `:boolean | :integer | :float | :string`, without implicit
  string parsing or numeric coercion. Limit string values to 1 KiB of valid UTF-8.
- `unit` is nil or a 1–32-byte UTF-8 string, not a dynamic atom or a unit-conversion
  framework.
- `expected_interval_ms` is nil or a positive integer. No expected interval means
  no age-based stale threshold. All inputs represent current observable state;
  there is no event kind.
- `min` and `max` are optional inclusive bounds of the output's numeric type, with
  `min <= max` when both are given. They must be nil for boolean/string outputs.
- `feedback_input_id` is an optional plugin-local input with the same type and unit.
  Registration order may differ; an absent, unavailable or incompatible input gives
  no usable reported value. This association is for reading/display, not confirmation.
- There is no platform `safe_value`, `on_stop` or confirmation tolerance field.
  Plugin-specific fallback and reconciliation policies belong to plugin configuration.

#### Observations and freshness

- The plugin supplies a local ID, value and quality. The platform supplies the full
  `input_id` and receipt timestamps.
- `quality` is `:good | :invalid | :unknown`. Good values must match the input's
  type. Invalid/unknown observations carry nil, never a fabricated usable value.
- `received_at_ms` is monotonic platform receive time in milliseconds, not necessarily
  sensor sampling time. It is never compared across VM boots.
- `received_at_utc` is a UTC `DateTime` or nil until clock synchronization. It is
  informational and never used for freshness.
- Every publication replaces the latest observation, including invalid/unknown
  samples and equal values with refreshed timestamps. Never fall back to an older
  good value when the newest observation is unusable.
- Availability, quality and freshness are separate read-model fields. An endpoint
  may be registered while its latest observation is stale or unknown.
- Freshness is computed when reading. Consumers that depend on freshness must also
  recheck with monotonic timers; a lack of new notifications does not prove freshness.

### Snapshots and notification hints

```elixir
{:nerves_gate_input_changed, full_id}
{:nerves_gate_output_changed, local_id}
```

Input subscribers read the current input snapshot. Output handlers read the current
live desired value. Neither notification contains an authoritative value or a
physical operation to execute.

- Subscriptions belong to the actual subscriber PID and are removed on its death.
  Subscribe before reading the initial snapshot to avoid a read/subscribe race.
- Consumers monitor the I/O controller and establish fresh subscriptions and reads
  after its loss. Old notifications cannot establish current availability.
- Input publication and binding changes mark that input dirty for each subscriber.
  Desired changes, including clearing desire, similarly dirty the bound handler's
  output. If no hint is outstanding, send one; later changes coalesce behind it.
- While the controller and recipient remain alive, dirty state eventually produces
  a hint without requiring another publication. Consumers tolerate duplicate hints,
  but correctness does not depend on recovering from arbitrary notification loss.
- The recipient's snapshot read atomically returns current state and clears its
  dirty flag in the controller. A later update sends another hint. Another PID's
  read cannot clear the recipient's flag. No explicit acknowledgement, event queue,
  replay or gap protocol is needed.
- Read functions drain already-queued hints for that endpoint in the actual caller
  before reading, so polling does not accumulate obsolete messages. An update racing
  with a read may leave a redundant hint; the consumer simply reads again.
- A handler reads its initial desired snapshot after registration; it must not rely
  on receiving an initial notification. Nil means no active target, not a default.

Ten changes may lead a consumer directly to the newest state. This is intentional.
A short button press can be missed; counting presses or running once per occurrence
requires a different future contract.

### Desired values and exclusive writers

Expose named domain operations to claim an output, set its desired value and release
it. Administrative calls use full IDs; plugin registration and handler calls use
local IDs in the caller's namespace.

- A claim belongs to the actual calling PID. Only that writer may set or release
  its desired value. Manual controls and automations use the same admission path.
- Claims and desired updates require an available output with an active binding.
  Reject competing writers and values outside the definition's type or bounds.
- Claiming an output alone leaves desired nil. A successful set means only that
  I/O stored the desired value, not that the device received or reached it.
- Setting an identical value is harmless; no one-notification-per-set guarantee is
  needed. A plugin must keep reconciling as appropriate even without another hint.
- Release or writer death clears desire and ownership. Notify a still-bound handler
  that its snapshot changed, but do not issue an implicit replacement value.
- Clearing desire stops it being an active target. It does not cancel an already
  started device operation, restore a previous value or prove physical safety.
- On plugin/binding loss, clear desire and ownership too. A new binding requires a
  fresh claim and explicit desired value, even if the old writer is still alive.

Keep output snapshots simple: definition, availability, whether claimed and desired
value. The owning PID stays private to the controller. Feedback is an ordinary input snapshot, optionally linked for display. Never
copy a desired value into that input or infer device success from storing desire.

### Plugin reconciliation and safety

The plugin reads current desire and decides how to converge the device toward it.
It owns serialization of its physical writes, polling, reconnects, retry timing and
protocol errors. It must not treat each notification as a mandatory separate write.

A new desired value may arrive during an older physical operation. The plugin
coordinates its own in-flight work and subsequent reconciliation; I/O does not
promise instantaneous convergence or cancellation. Repeat only operations whose
actual equipment semantics allow it.

Publish readback through an ordinary input, such as `pump.enabled`, and expose
communication failure through that input's quality or freshness. Reading a coil
proves its declared value, not that a pump is physically running; expose a separate
running input when that is the condition consumers need.

Shutdown/fallback behaviour is plugin-owned. Do not advertise a platform-enforced
stop policy. Device watchdogs and hardware interlocks are required where physical
safe-state guarantees are necessary.

**Acceptance:** firmware unit tests cover the three data contracts, definition
persistence and rejection of invalid saved data, namespace/PID ownership, generation
fencing, duplicate registrations, latest-value replacement, freshness without UTC,
subscribe-then-read, duplicate/coalesced notification hints, controller resubscription,
writer exclusivity, desired clearing on release/death/binding loss, fresh registration
and claims after restart, linked feedback and controller responsiveness during slow
plugin work. Verify that restart and writer loss cause no implicit physical write.
There are no command/event-delivery guarantees to test in this phase.

## 2. Publish the SDK contract

Transport operations are implemented in `NervesGateSDK.IO` using the three Phase 1
structs. Managed-activation host coverage is in place; rebuilt-guest qualification
and publication remain pending:

```elixir
register_input(input_definition)
publish_input(local_id, value, quality \\ :good)

register_output(output_definition, handler_pid)
read_desired(local_id)
```

Registration returns `{:ok, full_id}`; publication returns `{:ok, observation}`.
The bound handler reads `{:ok, value}` or `{:ok, nil}` when no desire is active.
Validation, membership and availability failures return `{:error, reason}`.
Do not conflate a false desired value with nil.

Plugin-supervised output handlers receive `{:nerves_gate_output_changed, local_id}`
and read current desire in their own PID. Feedback uses `publish_input/3`, not a
separate output-reporting API. Input snapshot/subscription and administrative
claim/set/release operations belong to the I/O domain; do not duplicate administrative
control as plugin SDK commands.

- Extend `NervesGateSDK.Backend` and `NervesGate.SDKBackend`.
- Preserve actual-caller membership and resource ownership; no proxy Tasks.
- Expose typed SDK data, not private domain maps or Jido/Runic/LiveFlow types.
- Bump the independent SDK version and update its changelog and README.

**Acceptance:** SDK contract tests, firmware backend tests using managed activation
fixtures, and a real QEMU SDK scenario for registration, publishing, reading live
desire, ordinary input feedback and lifecycle cleanup. Do not introduce a fake SDK
backend.

## 3. Add manual I/O controls

Add a native gateway I/O page showing:

- Inputs: definition, owning plugin, availability, latest observation, quality and
  freshness.
- Outputs: definition, availability, active writer, live desired value and optional
  linked feedback, with its independent quality and freshness.

Support validated manual claim/set/release operations. Reject manual writes while
an automation owns the output. Make it explicit that setting desire is not device
success and releasing ownership does not revert or stop the equipment.

UI controls call domain APIs, not plugin internals. Drafts stay separate from
projections, backend validation remains authoritative and projections never carry
ownership authority.

**Acceptance:** firmware web tests, rebuilt assets and a QEMU frontend scenario.

**Status:** implemented as the `/io` page backed by `NervesGate.IO.snapshot/0` and
`NervesGate.IO.Manual`, one supervised manual writer whose PID owns manual claims
(so they outlive browser tabs and any operator can release them). Firmware unit and
LiveView tests cover exclusivity against plugin/automation writers, validation,
drafts, release and binding loss; the QEMU `plugins` scenario renders `/io` on the
guest and drives a manual Modbus target against the plugin's own writer.

## 4. Integrate the Modbus plugin

Expose explicitly configured registers and coils:

- Register measurements as integer/float inputs.
- Discrete inputs/coils as boolean inputs.
- Only repeatable state-setting coils or holding registers as outputs. Exclude
  pulse, increment and command-trigger registers even when their wire type fits.

Keep polling, reconnects, register mapping, serialization and writes inside the
plugin's supervised protocol processes.

- Publish observations on change, configured deadband crossing or heartbeat.
- Read current desired state after notification, before reconciliation and after
  reconnect; do not replay queued hints as individual writes.
- Link ordinary feedback inputs where useful. State explicitly whether feedback
  describes a register/coil value or a physical equipment condition.
- Choose retry and readback policy based on the actual equipment's idempotent
  semantics. A transport timeout is a plugin concern, not an I/O request record.
- Keep shutdown/fallback policy in the plugin. Clearing desire does not write a
  fallback value on the plugin's behalf.
- Changed plugin artifacts require a new immutable plugin version.

**Acceptance:** existing plugin RTU/TCP tests and real QEMU scenarios covering an
input, desired-state reconciliation with feedback, reconnects, changed desire during
slow device I/O, loss of communication and plugin-owned shutdown. Physical
qualification requires separate authorization.

**Status:** implemented in plugin 0.3.0 as client/server definitions saved through
plugin configuration storage, with explicit Start/Stop. Plugin host tests cover validation,
storage and fail-closed admission; the QEMU `plugins` scenario covers the TCP
server/client roundtrip. QEMU has no RS485, so RTU between the EC100
ports awaits separately authorized physical testing.

## 5. Implement `NervesGate.Automation`

Use Jido only if Phase 0 approves it. Do not build a generic interchangeable-engine
framework or expose engine types in the public contract.

- Persist versioned automation documents referencing stable I/O IDs.
- Reject unsupported documents without automatic migration.
- Create automations disabled and require explicit enablement after reboot.
- Gate wall-clock scheduled execution on synchronized platform time. State-driven
  flows do not need UTC; use monotonic timers for freshness checks.
- Enabling an automation claims exclusive ownership of its outputs. Handle partial
  claim failure without leaving orphaned ownership.
- Subscribe before reading current input snapshots. Notifications trigger evaluation
  of current state, not once-per-transition execution or historical replay.
- Missing, invalid, unknown or stale required inputs block evaluation. Recheck
  freshness even when no notifications arrive.
- Missing outputs and writer conflicts block enablement.
- Establish every desired output through `NervesGate.IO`. The engine does not
  perform protocol writes or manage device retries.
- Disabling, blocking or losing the automation writer releases its claims and clears
  its desires. This does not request a fallback value or stop the equipment.
- Controller/binding loss blocks affected automations. Explicit re-enablement must
  reacquire outputs and evaluate fresh snapshots; do not restore old desired values.
- Engine recovery must not resurrect old ownership or treat stored flow progress as
  authority to drive outputs. A stopped instance cannot continue setting desire.

**Acceptance:** tests cover document persistence, scheduled-only clock gating,
restart and explicit re-enablement, missing/stale endpoints, missed intermediate
transitions, notification coalescing, ownership conflicts and partial claims,
disabling/blocking, writer loss and desired values remaining absent after recovery.

## 6. Integrate the LiveFlow editor

Proceed only if Phase 0 approves LiveFlow.

- Integrate it into the native gateway Automation UI.
- Edit the platform automation document format, not arbitrary Elixir modules.
- Offer I/O nodes from persisted definitions, displaying live availability separately.
- Keep the available logic operators deliberately small and state-based. Do not offer
  pulse, toggle, occurrence counting or once-per-event actions under an Output node.
- Validate every save in the backend.
- Show enabled/disabled/blocked execution status and actionable reasons.

**Acceptance:** document round trips, invalid graph rejection, unavailable
endpoints, web tests, rebuilt assets and real QEMU frontend coverage.

## Documentation and validation

Update as the implementation lands:

- `docs/architecture.md`: I/O, Automation, supervision and safety boundaries.
- `docs/action-api.md`: administrative ownership and desired-state controls.
- `sdk/README.md`: typed plugin I/O contract and notification-as-hint semantics.
- `docs/plugin-development.md`: registration, observations, reconciliation and
  plugin-owned shutdown.
- Modbus plugin README.
- `docs/ui.md`: I/O controls and Automation editor.
- Root, SDK and affected plugin changelogs/versions as appropriate.

Run focused tests while developing and root `mix check` plus `git diff --check`
before commits. Gateway source/UI changes require rebuilt firmware and assets.
Run focused QEMU scenarios only against the user-owned, verified Workbench session.
Report source checks, artifact builds and runtime qualification separately.
Documentation-only changes need no QEMU checks.

No part of this plan authorizes physical flashing, card formatting, equipment
writes, plugin activation, workstation network changes or a new bench lifecycle.

## Implementation order

```text
Dependency evaluation ───────────────────────────────────┐
                                                       ↓
I/O domain → SDK → Manual I/O UI → Modbus → Automation → LiveFlow
```
