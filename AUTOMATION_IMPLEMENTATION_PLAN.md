# Platform I/O and automation plan

## Execution status

Phases 1–5 are implemented. Automation work is paused until the official Jido v3
release; the current focus is repository cleanup, correctness and qualification of
the existing platform. Dependency evaluation resumes after that release, without
presuming adoption. Do not integrate Jido, Runic or LiveFlow, or build a temporary
automation engine during the pause.

## Model

The gateway runs one kind of thing: a feedback loop that acts only on fresh evidence
and only with current authority.

```text
WORLD
  ↓
Plugin ── Reading ──► IO ── inputs ──► Automation.decide(inputs, memory, context)
  ▲                                              │
  │                                            Desire
  │                                              ↓
  └──────── Plugin.apply(...) ◄──────────────── IO
  ↓
WORLD

Status observes the loop; it is not a step in it.
```

The **world** is the physical reality outside the gateway: rooms, valves, pumps,
water. The gateway never sees it directly. Everything it knows is second-hand,
decoded by a plugin and some time old. The model exists to stay honest about that gap.

```text
Plugin interprets hardware.
IO represents state and authority.
Automation decides (engine: candidate Jido).
Plugin reconciles decisions.
Hardware enforces safety.
```

The central separation: **observed state, occurrences, desired state and evidence of
success are different things.** Automation is not hard real-time and is not a safety
controller.

## Vocabulary

The public vocabulary is five words; a sixth is reserved.

| Word | Meaning | Produced by |
|---|---|---|
| **Reading** | the latest observation of one thing in the world, with quality and age | plugin |
| **Desire** | what the current controller of an output wants it to be | automation or operator |
| **Apply** | the plugin's attempt to make the world match a desire | plugin |
| **Status** | the gateway's judgement, from available evidence, of whether the world appears to match the desire | platform |
| **Authority** | who may currently create the desire for an output | IO |
| **Signal** (reserved) | something happened that is worth reacting to now | not in v1 |

- A Reading is evidence, not truth. A new Reading replaces the old one; there is no
  history. Quality is `:good | :invalid | :unknown`; age uses monotonic receipt time.
- A Desire is a repeatable state (`valve = 40%`, `pump = true`, `setpoint = 22.0`),
  never an action (`open`, `toggle`, `increment`). It exists only while its
  controller holds authority. Storing a Desire changes nothing in the world.
- Apply answers `:applied` (the operation appeared successful), `:unknown` (it may or
  may not have happened) or `{:failed, reason}`. `:applied` never proves the
  physical process reached the requested state.
- Status is `confirmed | pending | mismatch | unknown` (below).
- Authority is exclusive: one automation or the operator per output.
- Signals give responsiveness, Readings give correctness. A Signal that mirrors a
  Reading change adds nothing. Occurrences that must not be missed are durable
  counters (`press_count`, `pulse_count`). Signals are reserved until a concrete
  device needs one (see Deferred).

## Public interfaces

Three narrow interfaces hide the mechanism. **Hide mechanism, never hide
uncertainty:** no interface turns a doubt into a success.

### 1. Plugin: Readings and Apply

Plugins publish Readings and implement one callback per output kind:

```elixir
NervesGateSDK.IO.publish(id, value, quality \\ :good)

@behaviour NervesGateSDK.Output

@impl true
def apply(id, desired, state) do
  case Modbus.write_coil(state.device, coil(id), desired) do
    :ok -> {:applied, state}
    {:error, :timeout} -> {:unknown, state}
    {:error, reason} -> {{:failed, reason}, state}
  end
end
```

- The plugin starts the `NervesGateSDK.Output` runtime under its own supervisor. The
  runtime registers the outputs, runs `apply/3` in that plugin-owned process,
  serializes calls per output and always applies the newest Desire.
- `desired` is the typed value or `nil`. `nil` means no active Desire: the plugin
  performs its own declared release behaviour (for example hold or close). The
  platform never writes a fallback value.
- After reconnecting, the plugin asks the runtime to apply the current Desire again.
  Periodic reapplication is optional and plugin-chosen; repeat only operations whose
  equipment semantics are idempotent.
- Plugins own polling rates, decoding, retries, reconnects and readback. Readback and
  physical feedback are ordinary Readings.

**Hidden in the runtime:** registration, change hints and their draining, reading
Desires, claim epochs, discarding results from ended epochs and reporting Apply
outcomes. A plugin author never sees an epoch.

### 2. Automation: `decide/3`

An automation declares its inputs, outputs and freshness requirements and decides:

```elixir
def decide(inputs, memory, context) do
  {desires, memory}
end
```

```elixir
def decide(%{room: t, window: open?}, memory, context) do
  {valve, pi} = if open?, do: {0.0, memory.pi}, else: PI.step(memory.pi, 22.0, t, context.now_ms)
  {%{valve: valve}, %{memory | pi: pi}}
end
```

The three arguments are about different things:

| Argument | About | Example | From |
|---|---|---|---|
| `inputs` | the world | room 21.4 °C, window closed | Readings, already checked good and fresh |
| `memory` | the automation itself | PI integral, "heating since 06:00" | the previous `decide` |
| `context` | this moment and its own effect | now, UTC date, "my valve: mismatch" | the platform |

`context` is plain data, never a handle or function:

```elixir
%{
  now_ms: integer(),                 # monotonic, for timers and control time steps
  utc: DateTime.t() | nil,           # nil until the clock is synchronized
  outputs: %{atom() => :confirmed | :pending | :mismatch | :unknown}
}
```

Return contract:

- `desires` contains every declared output; `nil` clears that Desire. Undeclared
  keys, wrong types and out-of-range values move the automation to `fault`.
- `decide/3` is called only while every declared input is available, good and within
  its freshness limit, so it never handles nil, stale or unowned values.
- `memory` is not persisted unless the automation's document names the fields to
  keep (for example a PI integral). Time-based state such as derivative history
  always restarts from fresh samples.
- `decide/3` is pure by contract: no hardware, no IO calls, no messages. Trusted
  plugins share the BEAM, so this is a contract, not a sandbox.

Automation documents are data. Each names a controller kind implemented in firmware
(rule, schedule, PI, flow), its parameters and its I/O bindings. Each controller
kind implements `decide/3`. Documents never contain or load code.

**Hidden in the runtime:** reevaluation scheduling (change hints, coalescing,
freshness timers and later Signals), subscribe-before-read and resubscription,
quality and freshness gating, claims and partial-claim rollback, lifecycle states,
clearing Desires on block or fault, and explicit re-enable after reboot. The
runtime schedules an affected automation for reevaluation; authors do not depend on
how.

### 3. Status: did it work?

Every output has one Status, and every input reports `ok | stale | unavailable` with
its value and age. Status derives from available evidence: the Apply outcome and
the Readings declared as evidence for the output.

```text
confirmed   evidence agrees with the Desire
pending     the Desire changed recently; waiting for evidence within settle time
mismatch    settle time elapsed and evidence disagrees, or Apply failed
unknown     no Desire, or no usable evidence
```

Evidence rules:

1. **Stronger evidence wins:** physical over readback, readback over the Apply
   outcome. `:unknown` from Apply followed by a matching readback is `confirmed`;
   `:applied` followed by a contradicting physical Reading is `mismatch`.
2. **Apply alone never confirms.**

| Apply outcome, no feedback yet | Status |
|---|---|
| `:applied` | `pending` until settle time ends |
| `:unknown` | `pending`, then `unknown` |
| `{:failed, reason}` | `mismatch` with the reason |
| `:applied`, no evidence declared | `unknown`, showing "applied" as detail |

3. Only good Readings received after the Desire changed plus the evidence's settle
   time count. An earlier Reading can never confirm a new Desire.

Status is a diagnostic read model, never authority. It shows one word, with the
Desire, Authority, Apply outcome and each evidence entry available on drill-down.
For example: Desire, Apply and readback `true` with physical `false` indicates a
mechanical or electrical fault, not a communication fault.

## Rules

1. **Plugins own hardware semantics:** polling, decoding, Readings, writes, retries,
   reconnects, reconciliation, readback and release behaviour.
2. **Readings provide truth for decisions.** Correctness never depends on receiving
   every notification; the runtime reevaluates against current snapshots.
3. **Automations only decide.** They write only through IO. Serial/CAN/LAN handles
   and protocol sessions belong to plugin supervision, so there is nothing else to
   write through.
4. **Desires are state, not command streams.** Toggle, pulse, increment and other
   one-time effects are not outputs.
5. **IO arbitrates Authority.** One writer per output. Operators and automations use
   the same admission. In v1 an operator cannot override an automation's output
   without first disabling that automation; there is no priority arbitration.
6. **Apply preserves uncertainty.** The platform never retries an uncertain Apply.
7. **Feedback is ordinary input.** Desired, register feedback and physical state are
   reported separately.
8. **Polling is plugin policy; freshness is consumer policy.** Enabling an
   automation is rejected when it requires Readings fresher than the input's
   declared `expected_interval_ms`, with an actionable reason.
9. **Restart conservatively.** Definitions and automation documents persist.
   Readings, Authority, Desires, memory (unless declared) and executable hardware
   work do not. After reboot, plugins publish fresh Readings and automations stay
   disabled until explicitly enabled; they then claim outputs and decide from fresh
   Readings.
10. **Safety stays below automation.** Software interlocks ("window open blocks
    heating") are automation logic. E-stops, limit switches, overtemperature and
    overpressure cutoffs, motor overload and flame safety are independent hardware.
    Following these principles does not make the gateway a certified safety system.

## Implementation: hidden mechanism

### IO domain (`NervesGate.IO`)

One supervised firmware domain owns definitions, live plugin bindings, latest
Readings, subscriptions, Authority, claim epochs and Desires. It never performs
device operations and stays responsive during slow plugin work.

- **Persistence:** only validated definitions, using durable file persistence.
  Unsupported or unreadable saved definitions are rejected, never rewritten.
  Re-registration must match the saved definition.
- **Ownership:** only managed plugin activations register in their own namespace,
  derived from the actual caller. Output handlers must belong to the same
  activation. Loss of an owner, handler or activation makes endpoints unavailable,
  releases Authority and clears Desires. Old activations cannot publish into or read
  from new bindings. Checked stop fences new registrations, claims and Desires.
- **IDs:** local IDs are lowercase dotted segments of 1–128 bytes, never atoms. Full
  IDs prefix the plugin name (`modbus_plugin.pump.enable`).
- **Types:** `:boolean | :integer | :float | :string` without coercion; strings up to
  1 KiB of UTF-8; optional unit; numeric `min`/`max` for outputs.
- **Readings:** the plugin supplies value and quality; the platform adds the full ID,
  monotonic receipt time and UTC time when synchronized. Every publication replaces
  the latest Reading, including unusable ones; never fall back to an older good value.
  Freshness is computed when reading.
- **Hints:** `{:nerves_gate_input_changed, full_id}` and
  `{:nerves_gate_output_changed, local_id}` mark state dirty per recipient. One hint
  is outstanding at a time; later changes coalesce until the recipient reads, which
  clears its flag. Hints may be duplicated, never silently lost while both processes
  live. They carry no values.
- **Authority and epochs:** a claim belongs to the actual calling PID and increments
  a per-output `claim_epoch` (not "generation", which names plugin activations).
  Release, writer death and binding loss end the epoch and clear the Desire.
  Apply outcomes for an ended epoch are rejected. Epochs leave room for optional
  writer leases later.
- **Evidence:** output definitions declare evidence Readings, possibly from other
  plugins, each with a role (`:readback | :physical | :consequence | :estimate`), a
  settle time and an expectation from a closed set (`:equals`, `{:tolerance, delta}`,
  or per-Desire `{:above, x}`, `{:below, x}`, `{:equals, value}`). An optional
  `on_release` describes the plugin's release behaviour for operators; IO never
  performs it.
- **Status:** a pure function over IO snapshots, implementing the evidence rules.

### Output runtime (`NervesGateSDK.Output`)

A plugin-supervised process per output group. It owns the handler binding, drains
hints, reads the current Desire and epoch, calls `apply/3`, checks that the epoch is
still current before reporting, and reports the outcome to IO. A result from an
ended epoch is discarded. An epoch cannot cancel a write already on the wire; it
prevents treating stale work or an equal later Desire as current.

### Automation runtime (`NervesGate.Automation`)

Owns documents, controller kinds, scheduling and the lifecycle:

```text
disabled ─enable→ initializing ─inputs fresh→ running
running ─bad/stale input, or opted-in evidence mismatch→ blocked ─recovered→ running
any ─fault→ fault            any ─disable→ disabled
```

- `initializing` claims every output (rolling back partial claims), subscribes,
  reads fresh snapshots and resets time-based state.
- `blocked` and `fault` release claims and clear Desires; physical behaviour is the
  plugin's declared release behaviour.
- Degraded conditions raise existing `NervesGate.Alarms`. A trip moves the
  automation to `blocked` or `fault`. There is no software emergency level and no
  global fault-reason catalogue.
- Wall-clock schedules require synchronized UTC; state-driven automations use
  monotonic time only.
- An approved engine runs only inside `running`. Engine recovery never restores
  Authority, Desires or stored progress as permission to drive outputs.

### Estimates

Probabilistic fusion (for example current, vibration and temperature → "pump
running") is published by its producer as an ordinary Reading such as
`pump.running_estimate`, with documented confidence. The model lives in the producer.
The platform performs no inference; Status consumes estimates as `:estimate`
evidence with explicit thresholds.

## Current state

Phases 1–5 were exercised on rebuilt QEMU guests through the `plugins` scenario.
Phase 5 passed with Modbus 0.4.0: readback confirms an applied register, disagreeing
readback triggers reconciliation and confirmation again, manual Authority excludes
other writers, release writes nothing, and transport loss publishes unusable Readings.

- `NervesGate.IO` with schema-2 persisted definitions, bindings, Readings, coalesced
  hints, exclusive Authority with claim epochs, Desires, Apply outcomes and the pure
  `IO.OutputStatus` read model. Unsupported saved definitions disable I/O without
  stopping the controller or rewriting the file.
- SDK 0.2.0-dev.5: `NervesGateSDK.IO` (`register_input/1`, `publish/3`, input,
  output, subscribe and claim/set/release) and the `NervesGateSDK.Output` runtime
  with `apply/3`. SDK 0.2.0 publication is pending.
- The `/io` page with `NervesGate.IO.snapshot/0` and `NervesGate.IO.Manual`, showing
  Status with reason, Apply outcome, evidence and declared release behaviour.
- Modbus plugin 0.4.2 on the output runtime, with readback evidence and `:hold`
  release, plus plugin-first hardware assignment review. Tailnet 0.1.9 uses the
  same host-owned review before volatile network setup. Assignment never starts
  equipment communication. QEMU covers TCP; RTU between EC100 ports awaits
  separately authorized physical testing.

## Readiness baseline

The platform prerequisites for dependency evaluation are implemented; evaluation
remains paused until official Jido v3, and integration is not yet approved. The
accepted plugin-first hardware cutover extends the earlier `34a5671` baseline:

- Root `mix check`: 374 tests passed, including SDK, firmware, host tooling,
  generated-plugin and first-party plugin tests. The check and `git diff --check`
  passed again during repository cleanup. Non-fatal diagnostics remain for the
  existing SSH bare rescue and upstream yamodbus bitstring syntax.
- Recorded artifact qualification: x86_64 and EC100 firmware, including assets,
  built successfully. These builds were not repeated during repository cleanup.
- Recorded rebuilt-QEMU qualification: all 43 standard scenarios passed in one run
  (`32939124bc2759e6c993b022e4da9597:runner:1601`), with browser checks for
  plugin-first assignment and review survival across unload. Runtime checks were
  not repeated during repository cleanup. Opt-in `tailscale_auth` and physical
  hardware qualification were not included.
- SDKBackend precedes Plugins. Restoration is an explicit asynchronous job;
  Storage notifications and plugin-supervisor monitors replace readiness polling.
- No Jido, Runic or LiveFlow dependency or temporary automation engine is present.

Before adoption, Phase 0 must still establish target-build compatibility,
resource cost, bounded execution and ownership semantics. Passing platform tests
is not evidence that a future Jido dependency meets those requirements.
SDK publication and physical RTU qualification remain separately authorized work.
The existing boot-time fwup workaround remains until an upstream fix is adopted
and qualified; opening an upstream PR does not change the firmware dependency.

## Delivery

### 0. Evaluate Jido and LiveFlow

**Deferred until the official Jido v3 release.** Before integrating either
dependency, verify against the real code:

- EC100 and QEMU builds, footprint and compatibility with locked shared dependencies.
- Supervised, bounded execution and mailbox behaviour.
- Dynamic definitions without arbitrary code loading or atom creation.
- That lifecycle, reset rules and restart policy stay in `NervesGate.Automation`, with
  the engine behind `decide/3`.
- Jido's signal model: delivery, ordering, bounds and ownership.
- LiveFlow's fit with the Phoenix/LiveView gateway asset pipeline.
- License, maintenance and release maturity.

**Deliverable:** a short use/defer/reject decision per dependency. Do not build a
temporary rule engine while waiting.

### 1–4. IO domain, SDK transport, manual controls, Modbus

Done as described in Current state. Remaining: SDK 0.2.0 publication (separate
request) and physical RTU qualification (separate authorization).

### 5. Plugin output runtime, epochs, evidence and Status

**Status:** implemented with passing SDK, firmware unit/web and Modbus host tests;
rebuilt-guest `plugins` qualification passed (185 seconds).

The current SDK contract has no compatibility aliases:

- `IO.Reading` and `IO.publish/3` describe observed state.
- `NervesGateSDK.Output` owns output registration, hints and epoch-checked Apply
  reporting; plugins implement `apply/3`.
- Outputs declare evidence and `on_release` behaviour.
- `/io` shows derived Status, Apply outcomes and evidence details.
- Modbus 0.4.0 uses the output runtime.

**Acceptance:** SDK contract tests and firmware unit tests for epoch increments,
rejection of ended-epoch outcomes, equal Desires across epochs, evidence validation,
settle timing on monotonic receipt, cross-plugin evidence, the Status table and
evidence precedence; output-runtime tests in a real managed activation for newest
Desire, discarded superseded outcomes, release and reapply; LiveView tests for `/io`;
the QEMU `plugins` scenario confirms a Modbus output through readback, including
after a disagreeing readback is reapplied.

### 6. Automation runtime

Use the engine only if Phase 0 approves it; do not build an interchangeable-engine
framework or expose engine types.

- Versioned documents referencing full I/O IDs; unsupported documents rejected
  without migration.
- Controller kinds implementing `decide/3`, starting with rule and PI; schedules
  once UTC gating exists.
- The lifecycle, `context`, return contract and memory rules above.
- Enable-time validation: outputs exist and are free, freshness requirements are
  compatible with declared input intervals.

**Acceptance:** tests for document persistence, scheduled-only clock gating,
restart and explicit re-enable, lifecycle transitions and reset rules, freshness
gating and timer rechecks, missed intermediate transitions, coalescing, ownership
conflicts and partial claims, return-contract violations, writer loss and Desires
remaining absent after recovery; a QEMU scenario driving a Modbus output from an
automation.

### 7. LiveFlow editor

Only if Phase 0 approves LiveFlow. It edits the `flow` controller kind's documents in
the native gateway Automation UI, never Elixir modules.

- Offer I/O nodes from persisted definitions with live availability shown separately.
- Keep operators small and state-based; no pulse, toggle, counting or once-per-event
  actions on Output nodes.
- Validate every save in the backend.
- Show lifecycle state, actionable reasons and output Status.

**Acceptance:** document round trips, invalid graph rejection, unavailable endpoints,
web tests, rebuilt assets and a real QEMU frontend scenario.

## Plugin author conventions

- Expose occurrences that must not be missed as counters or sequence numbers.
- Declare output evidence and `on_release`; say whether feedback is a register/coil
  value or a physical condition.
- Publish estimates as Readings with documented confidence and model ownership.
- A hardware watchdog or safety MCU is a plugin owning its serial port and heartbeat,
  with the fallback in the MCU. Whether a deployment needs one is a hardware decision.

## Deferred

- **Signals:** plugin-emitted occurrences for latency and payloads, with their own
  ingress outside the latest-value store. Requires a concrete device case, Phase 0's
  Jido findings, managed-activation ownership, namespaced IDs, bounded mailboxes and
  a drop policy. Signals stay advisory; counters remain authoritative.
- **Writer leases:** optional claim TTLs against a live but wedged writer. Renewal
  must come from the evaluation loop itself, never a separate timer process.
- **Commands:** only for a concrete device case that Desires cannot express.
- **Operator override priority** (hand/off/auto semantics), if v1's explicit-disable
  rule proves insufficient.

## Documentation and validation

Update as each phase lands: `docs/architecture.md`, `docs/action-api.md`,
`sdk/README.md`, `docs/plugin-development.md`, the Modbus plugin README, `docs/ui.md`
and the root, SDK and plugin changelogs and versions.

Run focused tests while developing and root `mix check` plus `git diff --check` before
commits. Gateway source and UI changes require rebuilt firmware and assets. Run QEMU
scenarios only against the user-owned, verified Workbench session. Report source
checks, artifact builds and runtime qualification separately. Documentation-only
changes need no QEMU checks.

No part of this plan authorizes physical flashing, card formatting, equipment
writes, plugin activation, workstation network changes or a new bench lifecycle.

## Order

```text
Now: maintain and qualify the implemented platform (1–5).

After official Jido v3:
Dependency evaluation (0) → Automation (6) → LiveFlow (7)
                            only if approved
```
