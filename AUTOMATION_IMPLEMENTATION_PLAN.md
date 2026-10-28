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
- Every output declares a safe value.
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

- Persist definitions, not PIDs, writer leases, monotonic timestamps or pending work.
- Reject unsupported persisted data explicitly; never migrate or erase it automatically.
- Latest values after a reboot are unknown until fresh observations arrive.

### Registration and lifecycle

- Only managed plugin activations may register endpoints within their own namespace.
- Derive membership from the actual caller using Plugins-owned generation bindings.
- A re-registration must match the saved definition or be rejected explicitly.
- Endpoints become unavailable when their live owner or activation disappears.
- A new activation cannot complete requests belonging to an older generation.
- Stable IDs in saved automations remain independent of live PIDs and generations.

### Inputs and observations

Input definitions contain:

- Local ID and platform-derived plugin namespace.
- Value type.
- Optional unit.
- Kind: measurement, state or event.
- Optional expected interval for freshness checks.

Observations contain:

- Input ID and value.
- Quality: good, invalid or unknown.
- Monotonic receive time.
- UTC time when the platform clock is synchronized.

Derive staleness from freshness metadata rather than persisting a stale flag.
Subscriptions belong to the actual subscriber PID and disappear when it exits.

### Outputs

Output definitions contain a value type, optional unit, safe value and any
required validation bounds. Distinguish setpoints from commands where their
execution semantics differ.

Output request states:

```text
idle → pending → accepted → confirmed
                    └────→ failed / unknown
```

- Each request has an identity, deadline, requester and target plugin generation.
- Acceptance is not physical confirmation; feedback/readback is separate evidence.
- Unknown outcomes block further writes until explicitly resolved.
- No automatic replay or retry of an uncertain request.
- Start with one exclusive writer per output, not priorities or last-writer-wins.

### Safe values

Request the safe value when an automation is disabled or its writer is lost. On
checked plugin stop, apply safe values before releasing protocol connections.

Keep ownership fenced while safe-value application is pending or uncertain;
releasing a writer must not admit another write that races with cleanup.

A crashed plugin or disconnected device cannot guarantee physical safety. Report
failure or uncertainty honestly. Device watchdogs and hardware interlocks are
required where physical safe-state guarantees are necessary.

**Acceptance:** firmware unit tests cover validation, persistence, namespace and
PID ownership, generation fencing, duplicate registrations, freshness, late
replies, writer exclusivity, stop/crash behaviour, safe-value outcomes and
controller responsiveness.

## 2. Publish the SDK contract

Add `NervesGateSDK.IO` with the initial interface:

```elixir
register_input(definition)
publish(local_id, value, quality \\ :good)

register_output(definition, handler_pid)
report_output(request_id, result)
```

Plugin-supervised output handlers receive:

```elixir
{:nerves_gate_output, request_id, local_id, value, deadline}
```

Initial result vocabulary:

```elixir
:accepted | :confirmed | {:failed, reason} | :unknown
```

- Extend `NervesGateSDK.Backend` and `NervesGate.SDKBackend`.
- Preserve actual-caller membership and resource ownership.
- Expose typed SDK data, not private domain maps or Jido/Runic/LiveFlow types.
- Bump the independent SDK version and update its changelog and README.

**Acceptance:** SDK contract tests, firmware backend tests using managed activation
fixtures, and a real QEMU SDK scenario for registration, publishing, output
delivery and lifecycle cleanup. Do not introduce a fake SDK backend.

## 3. Add manual I/O controls

Add a native gateway I/O page showing:

- Inputs: definition, owning plugin, availability, latest value and freshness.
- Outputs: definition, availability, safe value, active writer and request outcome.

Support:

- Validated manual output requests.
- Clear rejection while automation owns an output.
- Explicit resolution of unknown outcomes without replaying the original request.

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

- Publish on change, configured deadband crossing or heartbeat.
- Confirm physical values through readback/feedback, not merely write acceptance.
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
- Missing or stale required inputs block execution.
- Missing outputs and writer conflicts block enablement.
- Route every output request through `NervesGate.IO`.
- Disabling releases ownership only after checked safe-value handling.
- Restart or recovery never replays an uncertain physical operation.

**Acceptance:** tests cover persistence, clock gating, restart, missing/stale
endpoints, conflicts, disabling, writer loss and uncertain output outcomes.

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
