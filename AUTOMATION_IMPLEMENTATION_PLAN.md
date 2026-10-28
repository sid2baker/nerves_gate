# Platform I/O and automation implementation plan

## Goal and boundaries

Make automation a first-class Nerves Gate subsystem. Plugins own device protocols
and equipment semantics; the platform owns shared I/O and automation infrastructure.

```text
hardware → plugin → observation → automation → output → plugin → hardware
```

- `NervesGate.IO` owns definitions, live bindings, observations, subscriptions and
  output ownership.
- `NervesGate.Automation` owns automation persistence and execution.
- Jido is a candidate internal execution dependency, not part of the public contract.
- LiveFlow is a candidate native gateway editor, not an execution engine.
- Plugins keep protocol connections and physical effects in their supervised processes.

Automation is not hard real-time and is not a safety controller.

## Agreed decisions

- IDs are plugin-scoped strings, such as `modbus_plugin.pump.enable`. The platform
  derives the plugin namespace from the actual calling process.
- Initial value types: boolean, integer, float and string.
- Definitions persist across reboot; live registrations do not. Saved endpoints
  remain unavailable until their owning plugin registers again.
- Persist minimal output request intent before dispatch and its outcome afterward.
  Unfinished requests recover as unknown, never as executable work to replay.
- State/measurement inputs have latest values; event inputs deliver occurrences,
  not durable current state.
- Desired output values, reported values and write-request outcomes are separate.
- Every output declares a safe value; configuring one does not guarantee safety.
- Manual output control is supported through the same validation and command path.
  It is rejected while an automation owns that output.
- Automations wait for the platform clock to be synchronized. Deadlines and
  freshness use monotonic time.
- No models, beliefs, generic engine-adapter framework, distributed execution,
  historical replay or priority-based output arbitration in the first release.
- Keep the implementation small: start with one I/O domain rather than separate
  Registry, LatestValues and Subscriptions services.

## 0. Evaluate Jido and LiveFlow

Before integrating either dependency, verify:

- EC100 and QEMU build compatibility and dependency footprint.
- Compatibility with shared firmware dependencies and locked versions.
- Supervised execution, bounded work and mailbox behaviour.
- Dynamic flow definitions without arbitrary code loading or atom creation.
- Restart, checkpoint and durable wait/resume semantics.
- Side-effect handling that does not automatically retry uncertain output writes.
- Compatibility with the current Phoenix/LiveView and gateway asset pipeline.
- License, maintenance and release maturity.

Inspect the actual Jido/Runic integration rather than assuming the proposed APIs
or durability guarantees exist.

**Deliverable:** a short use/defer/reject decision for each dependency. The I/O
work can proceed independently of this evaluation. Do not build a temporary rule
engine while waiting for Jido.

## 1. Implement `NervesGate.IO`

Add a supervised firmware domain owning:

- Persisted input and output definitions.
- Live registrations bound to the actual plugin activation generation.
- Latest observations and subscriptions.
- Output request state and exclusive writer ownership.

Keep the controller responsive while plugin commands execute. Deliver effects to
plugin-supervised handler processes, never through a blocking device operation in
the I/O controller.

### Persistence

Use the existing persistence approach under `/data`. Evaluate PropertyTable's
persistence support before choosing it; do not assume an in-memory table is durable.

- Persist definitions and a bounded per-output request record, not PIDs, writer
  leases, activation references, observation references or monotonic timestamps.
- Before dispatching a request, durably record its ID, output ID, requested value,
  stable requester identity and pending status. The requested value records intent,
  not a job to execute on restart. No successful durable write means no dispatch.
- Durably record a terminal outcome before acknowledging it or admitting another
  write. A persistence failure leaves the output blocked; no physical write is retried.
- Keep only the current/unresolved or most recent request per output. This is not
  an event log or a general durable workflow system.
- Reject unsupported, corrupt or unreadable saved data explicitly. Never replace
  it with an empty registry or clear uncertainty to make startup succeed.
- Latest observations and reported values are unknown after a reboot. A saved
  desired value is historical intent only; it never drives automatic reconciliation.

On an I/O-controller or gateway restart, restore pending/accepted requests as
`unknown` and retain existing unknown requests. Endpoints remain unavailable until
rebound. New bindings do not clear output uncertainty. An old terminal outcome is
history, not evidence of the device's current state.

Recovery must cover these crash windows:

| Crash point | Recovery |
| --- | --- |
| Before durable intent | No request was dispatched |
| After durable intent, before delivery | Unknown; delivery cannot be inferred |
| After delivery or acceptance | Unknown; never resend |
| After device evidence, before durable outcome | Unknown; fresh read-only verification is needed |
| After durable terminal outcome | Keep the historical outcome; require fresh observations |

PropertyTable may hold live values or notifications, but it is suitable for request
intent only if its actual persistence guarantees satisfy this ordering.

### Registration and lifecycle

- Only managed plugin activations may register endpoints within their own namespace.
- Derive membership from the actual caller using Plugins-owned generation bindings.
- A re-registration must match the saved definition or be rejected explicitly.
- Endpoints become unavailable when their live owner or activation disappears.
- A new activation cannot complete requests belonging to an older generation.
- Validate output handler membership as well as the registering caller. Both must
  belong to the same activation; only the bound handler may report request outcomes.
- During checked stop, fence new registrations and normal commands. Allow only
  completion/feedback for admitted work and the owned safe-value cleanup while the
  generation is quiescing; revoke it only after checked cleanup.
- Stable IDs in saved automations remain independent of live PIDs and generations.

### Initial structs

These are proposed SDK data contracts, not implemented modules. Keep the four
structs under `NervesGateSDK.IO`; firmware uses the same data rather than mirroring
it with another set of types.

```elixir
defmodule NervesGateSDK.IO.InputDefinition do
  @enforce_keys [:id, :type, :kind]
  defstruct [:id, :type, :kind, :unit, :expected_interval_ms]
end

defmodule NervesGateSDK.IO.OutputDefinition do
  @enforce_keys [:id, :type, :safe_value]
  defstruct [:id, :type, :safe_value, :unit, :min, :max, :feedback_input_id]
end

defmodule NervesGateSDK.IO.Observation do
  @enforce_keys [:ref, :input_id, :value, :quality, :received_at_ms]
  defstruct [:ref, :input_id, :value, :quality, :received_at_ms, :received_at_utc]
end

defmodule NervesGateSDK.IO.OutputRequest do
  @enforce_keys [:id, :output_id, :value, :deadline_ms]
  defstruct [:id, :output_id, :value, :deadline_ms, :reason, status: :pending]
end
```

#### Definition fields

- Definition `id` is a plugin-local string, for example `pump.enable`. Accept
  lowercase letter-led segments containing lowercase letters, digits or underscores,
  separated by dots, with a total length of 1–128 bytes. Never convert IDs to atoms.
- Catalogues and saved automations use the full ID, formed from the caller-derived
  plugin name and local ID. Registration returns that full ID. Definitions retain
  their local IDs and are persisted under their full catalogue keys.
- Inputs and outputs share the plugin namespace. Reject conflicting definitions,
  duplicate live owners or reuse of an input ID for an output. Identical registration
  by the current owner is idempotent; rebinding an unavailable endpoint follows the
  saved-definition and generation checks above.
- `type` is exactly `:boolean | :integer | :float | :string`, without implicit
  string parsing or numeric coercion. Limit string values to 1 KiB of valid UTF-8.
- `unit` is nil or a 1–32-byte UTF-8 string, such as `"kW"` or `"celsius"`, not a
  dynamic atom or a unit-conversion framework.
- Input `kind` is `:measurement | :state | :event`.
- `expected_interval_ms` is nil or a positive integer for measurements/states;
  it must be nil for events. No expected interval means no age-based stale threshold.
- `min` and `max` are optional inclusive bounds of the output's numeric type, with
  `min <= max` when both are given. They must be nil for boolean/string outputs.
  Validate safe values and requested values identically.
- `feedback_input_id` is an optional plugin-local state/measurement input with the
  same type and unit. Registration order may differ, but confirmation requires a
  matching live input from the same plugin activation.

The first output contract sets typed values. Do not infer pulse, toggle or
one-shot command semantics from a value; those require an explicit later contract.

#### Observation fields and input semantics

- `input_id` is the full ID. The platform supplies `ref`, `input_id` and timestamps;
  plugins supply only the local ID, value and quality when publishing.
- `ref` is an opaque reference for this observation in this I/O-controller lifetime.
  It is not persisted, exposed in UI projections or supplied by a publisher.
- `quality` is `:good | :invalid | :unknown`. Good values must match the input's
  type. Invalid/unknown observations carry nil, not a fabricated usable value.
- `received_at_ms` is platform monotonic time in milliseconds. It measures receipt,
  not necessarily sensor sampling time. It is never compared across VM boots.
- `received_at_utc` is a UTC `DateTime` or nil until clock synchronization; it is
  informational and never used for deadlines or freshness.
- Measurements/states replace the latest observation even when the new quality is
  invalid/unknown. Keep freshness, quality and endpoint availability distinct;
  never fall back silently to an older good value.
- Events are individual occurrences delivered to current subscribers. Repeated
  equal values are distinct events; do not coalesce them as unchanged state.
- An event has no current value, age-based stale state or subscription snapshot.
  Events during downtime are not replayed, and loss of events is possible. A device
  requiring recoverable state should also expose a state input.

Subscriptions belong to the actual subscriber PID. Bound delivery and make
subscription loss/overflow explicit rather than silently discarding events or
allowing unbounded mailboxes. Dependent automations become blocked on a detected
subscription gap; a fresh subscription does not reconstruct missed events.

### Output values and request lifecycle

Keep three separate pieces of information in the output read model:

- `desired`: the latest admitted request's ID and requested value, or nil.
- `reported`: the latest linked feedback observation, or nil, with its own quality
  and freshness. Never copy desired values into reported values.
- `request`: the most recent `OutputRequest`, or nil, describing an individual write.

A failed write can leave desired and reported different. Neither changing a
reported value nor reading a saved desired value creates a new request.

`OutputRequest` fields have these meanings:

- `id`: a platform-generated unique string, persisted before dispatch.
- `output_id`: the full output ID; `value`: this request's immutable target value.
- `deadline_ms`: a platform-owned absolute monotonic deadline for this VM lifetime;
  nil in a recovered historical/unknown request. Timeout does not cancel an effect.
- `status`: `:pending | :accepted | :confirmed | :failed | :unknown`.
- `reason`: nil or a safe bounded explanation owned by the domain, not raw device
  payloads or arbitrary exception terms.

The controller privately retains requester/writer ownership, handler PID and plugin
generation bindings; these are not SDK request fields. Only the stable requester
identity is journalled, never an executable caller or a live authority token.
`idle` means there is no request; it is not a request status.

| Current state | Allowed next state | Evidence |
| --- | --- | --- |
| No request | pending | Validated request and durable intent, before delivery |
| pending | accepted | Bound handler accepted this request; no proof of device state |
| pending or accepted | confirmed | Correlated, fresh device feedback meeting the rule below |
| pending or accepted | failed | Known unsuccessful outcome, with no ambiguous effect still in flight |
| pending or accepted | unknown | Ambiguous timeout, handler/generation loss or interrupted recovery |
| unknown | confirmed or failed | Explicit resolution after fencing in-flight work and read-only verification |

`confirmed` and `failed` are terminal for a request. New writes get new IDs.
Unknown is blocked, not a retryable failure. A late ordinary report cannot clear
unknown, regress a terminal outcome or update a different generation's request.
Exact duplicate reports are harmless and never cause another effect.

Before issuing a physical effect, the handler checks the request's live binding
and deadline. An expired request known not to have started may fail without an
ambiguous effect; once execution may have started, elapsed time alone is not proof
of failure or cancellation.

#### Confirmation and explicit resolution

Reserve confirmation for evidence of the requested endpoint state, not a transport
acknowledgement. The handler reports `{:confirmed, observation_ref}`. I/O verifies
that the reference identifies the current good, non-stale linked feedback sample,
from the same live generation, received after dispatch and exactly matching the
requested typed value. The handler is responsible for correlating the sample with
post-write device feedback, not a cached pre-write value.

If the output has no feedback input, acceptance cannot be promoted to confirmation.
An accepted request without sufficient evidence becomes unknown at its deadline.

Confirmation proves only the endpoint's declared meaning: reading back a Modbus
coil proves that coil's value, not that a pump is physically running. Expose a
separate running-feedback input if that is what an automation needs to establish.

Resolution of unknown outcomes is a separate explicit administrative action, bound
to the output and request ID. It must fence any old work that could still complete
and obtain fresh device evidence before recording confirmed or failed durably. A
current value different from the target does not by itself prove that the earlier
write never took effect. Resolution is not an unchecked acknowledgement or a replay
of the original command. If the outcome cannot be established, leave the output blocked. A new plugin generation
may provide fresh observations for resolution, but cannot finish the old request
through its ordinary SDK report path.

Start with one exclusive writer per output. Manual and automation requests use
the same admission rules; ownership changes do not clear uncertainty.

### Safe values

Request the safe value when an automation is disabled or its writer is lost. On
checked plugin stop, apply safe values before releasing protocol connections.

Keep ownership fenced while safe-value application is pending or uncertain;
releasing a writer must not admit another write that races with cleanup. A safe
value is a new request through the same durable-intent and confirmation path,
not an exemption from the unknown-outcome block. Do not race it against an earlier
in-flight write; fence/resolve that write first. A definite safe-value failure also
keeps cleanup blocked until an explicitly authorized action succeeds.

**A configured safe value is not a physical safety guarantee.** A crashed plugin
or disconnected device cannot guarantee physical safety. Report failure or
uncertainty honestly. Device watchdogs and hardware interlocks are required where
physical safe-state guarantees are necessary. Make this distinction prominent in
SDK, plugin and operator documentation.

**Acceptance:** firmware unit tests cover the four data contracts, persistence,
namespace and PID ownership, generation fencing, duplicate registrations,
freshness, repeated equal events, subscription loss, late/duplicate reports,
writer exclusivity, every crash window in the table above, stop/crash behaviour,
confirmation evidence, explicit resolution, safe-value outcomes and controller
responsiveness. Define these contracts and transitions before implementing the
controller.

## 2. Publish the SDK contract

Add `NervesGateSDK.IO` using the four structs specified in Phase 1:

```elixir
register_input(input_definition)
publish(local_id, value, quality \\ :good)

register_output(output_definition, handler_pid)
report_output(request_id, result)
```

Registration returns `{:ok, full_id}`; publication returns `{:ok, observation}`.
Reports return `:ok` after the state transition is checked and any required outcome
persistence succeeds. Validation/admission failures return `{:error, reason}`.
Publishing and reporting run in the actual managed caller, not a proxy Task.

Plugin-supervised output handlers receive the typed request:

```elixir
{:nerves_gate_output, %NervesGateSDK.IO.OutputRequest{} = request}
```

Result vocabulary for ordinary handler reports:

```elixir
:accepted | {:confirmed, observation_ref} | {:failed, reason} | :unknown
```

There is no bare `:confirmed`: acceptance and device feedback are distinct.
Explicit resolution of an unknown request belongs to the administrative domain
API, not `report_output/2`.

- Extend `NervesGateSDK.Backend` and `NervesGate.SDKBackend`.
- Preserve actual-caller membership and resource ownership.
- Expose typed SDK data, not private domain maps or Jido/Runic/LiveFlow types.
- Bump the independent SDK version and update its changelog and README.

**Acceptance:** SDK contract tests, firmware backend tests using managed activation
fixtures, and a real QEMU SDK scenario for registration, publishing, output
delivery and lifecycle cleanup. Do not introduce a fake SDK backend.

## 3. Add manual I/O controls

Add a native gateway I/O page showing:

- Inputs: definition, owning plugin, availability, latest measurement/state and
  freshness. Event inputs show live occurrences, not a latched current value.
- Outputs: definition, availability, safe value, active writer, desired value,
  reported feedback and the separate request outcome.

Support:

- Validated manual output requests.
- Clear rejection while automation owns an output.
- Evidence-based explicit resolution of unknown outcomes without replaying the
  original request or merely clearing a blocked flag.

UI controls call domain APIs, not plugin internals. Drafts stay separate from
projections, and backend validation remains authoritative.

**Acceptance:** firmware web tests, rebuilt assets and a QEMU frontend scenario.

## 4. Integrate the Modbus plugin

Expose explicitly configured registers and coils:

- Register measurements as integer/float inputs.
- Discrete inputs/coils as boolean inputs.
- Coils or holding registers as outputs.

Keep polling, reconnects, register mapping and writes inside the plugin's
supervised protocol processes.

- Publish state/measurement observations on change, configured deadband crossing
  or heartbeat; event occurrences must not be coalesced by value.
- Link output feedback inputs and report confirmation with a fresh post-write
  observation reference, not merely a write acknowledgement. State explicitly
  whether feedback proves a register/coil value or a physical equipment condition.
- A write timeout produces an unknown outcome and is never automatically replayed.
- Checked stop applies safe values before releasing connections.
- Changed plugin artifacts require a new immutable plugin version.

**Acceptance:** existing plugin RTU/TCP tests and real QEMU scenarios covering an
input, an output with feedback, uncertainty and safe stop. Physical qualification
requires separate authorization.

## 5. Implement `NervesGate.Automation`

Use Jido only if Phase 0 approves it. Do not build a generic interchangeable-engine
framework or expose engine types in the public contract.

- Persist versioned automation documents referencing stable I/O IDs.
- Reject unsupported documents without automatic migration.
- Create automations disabled and require explicit enablement after reboot.
- Gate execution on synchronized platform time.
- Enabling an automation claims exclusive ownership of its outputs.
- Missing, invalid, unknown or stale required state/measurement inputs block execution.
- Event inputs trigger occurrences, not persistent conditions; no events are replayed
  after a restart. A detected subscription gap blocks dependent automations.
- Missing outputs, unresolved requests and writer conflicts block enablement.
- Route every output request through `NervesGate.IO`.
- Disabling releases ownership only after checked safe-value handling. If an enabled
  automation becomes blocked by lost input availability, freshness or subscription,
  stop normal actions and use the same safe-value cleanup rules without bypassing
  unresolved requests.
- Restart or recovery never replays an uncertain physical operation. Engine-level
  retries and durable flow resumption cannot bypass I/O's unresolved-request fence.

**Acceptance:** tests cover persistence, clock gating, restart, missing/stale
endpoints, event occurrence/loss semantics, conflicts, disabling, writer loss and
uncertain output outcomes, including engine recovery across an in-flight write.

## 6. Integrate the LiveFlow editor

Proceed only if Phase 0 approves LiveFlow.

- Integrate it into the native gateway Automation UI.
- Edit the platform automation document format, not arbitrary Elixir modules.
- Offer I/O nodes from persisted definitions, displaying live availability separately.
- Keep the available logic operators deliberately small.
- Validate every save in the backend.
- Show enabled/disabled/blocked execution status and actionable reasons.

**Acceptance:** document round trips, invalid graph rejection, unavailable
endpoints, web tests, rebuilt assets and real QEMU frontend coverage.

## Documentation and validation

Update as the implementation lands:

- `docs/architecture.md`: I/O, Automation, supervision and safety boundaries.
- `docs/action-api.md`: administrative controls and outcomes.
- `sdk/README.md`: typed plugin I/O contract.
- `docs/plugin-development.md`: registration, observations, output handling and cleanup.
- Modbus plugin README.
- `docs/ui.md`: I/O controls and Automation editor.
- Root, SDK and affected plugin changelogs/versions as appropriate.

Run focused tests while developing and root `mix check` plus `git diff --check`
before commits. Gateway source/UI changes require rebuilt firmware and assets.
Run focused QEMU scenarios only against the user-owned, verified Workbench session.
Report source checks, artifact builds and runtime qualification separately.

No part of this plan authorizes physical flashing, card formatting, equipment
writes, plugin activation, workstation network changes or a new bench lifecycle.

## Implementation order

```text
Dependency evaluation ───────────────────────────────────┐
                                                       ↓
I/O domain → SDK → Manual I/O UI → Modbus → Automation → LiveFlow
```
