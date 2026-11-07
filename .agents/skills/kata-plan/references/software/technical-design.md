# Design the Software Change

Turn the settled product outcome and grounded current state into one coherent
technical direction. Plan the behavior and integration. Do not pre-write the
implementation.

## Describe current and target behavior

State the smallest end-to-end flow that explains the change:

```text
entry -> validation -> domain action -> state or side effect -> result
```

For the current state, name the components and contracts that exist. For the
target state, name what changes and what stays stable. Use a diagram only when
it makes ownership, sequence, or state easier to understand than prose.

## Select one primary approach

Choose the approach that best fits the Product Contract, repository
architecture, existing patterns, and delivery constraints. Record each
load-bearing decision as `KTD<n>` with:

- **Decision:** What the plan selects.
- **Reason:** Which requirement, evidence, or constraint makes it suitable.
- **Rejected alternative:** The strongest credible alternative and why it
  loses here.
- **Consequences:** Compatibility, sequencing, risk, or future limits.
- **Governs:** The requirements and implementation units controlled by the
  decision.

Do not create alternatives for small coding choices. Do not reopen product
scope as a technical alternative. If two approaches remain valid because the
user values different tradeoffs, ask before selecting one.

## Define system boundaries

For each affected boundary, specify the target contract and compatibility
rules:

- module, process, package, or service ownership;
- public and internal APIs;
- events, signals, jobs, queues, or callbacks;
- persisted records, caches, files, and generated artifacts;
- configuration and feature controls;
- external systems and failure behavior; and
- user or agent entry points.

Name request and response shapes, state invariants, and error semantics when
they affect implementation or tests. Use directional pseudo-code, schemas, or
state diagrams only when they express a decision more precisely than prose.
Label them as design guidance, not code to copy.

## Apply conditional risk checks

Use the checks below only when their trigger is present. Record the resulting
design decision, unit, test, or explicit non-effect. Do not add empty boilerplate.

### Public interface or compatibility

Trigger: a public API, library contract, serialized value, stored schema,
configuration key, protocol, or downstream caller can change.

Define version behavior, compatibility window, deprecation or migration path,
caller order, and contract tests. Prefer additive change before removal.

### Data or schema change

Trigger: persisted meaning, schema, index, stored format, backfill, or data
ownership changes.

Define invariants, expand and contract order, old-code and new-code
compatibility, backfill and batching, transaction boundaries, rollback limits,
verification queries, privacy, and retention. Never assume test fixtures match
production data.

### Authentication, authorization, or sensitive data

Trigger: identities, permissions, secrets, personal data, trust boundaries, or
externally supplied input are involved.

Define the actor, permission check, trusted boundary, validation, redaction,
audit, failure behavior, and misuse tests. Do not change policy through an
implementation detail.

### Asynchronous or concurrent work

Trigger: processes, tasks, queues, callbacks, retries, distributed nodes,
parallel writes, or long-running operations are involved.

Define ownership, ordering, idempotency, deduplication, timeouts, retry limits,
cancellation, partial completion, resume behavior, race handling, and
termination signals.

### Runtime lifecycle

Trigger: startup, shutdown, supervision, resource acquisition, registration,
activation, upgrade, or recovery changes.

Define lifecycle states, legal transitions, owner process, restart behavior,
resource cleanup, readiness, and recovery from a partial transition.

### Dependency or platform change

Trigger: a library, framework, service, runtime, toolchain, or platform contract
changes.

Confirm the current version and authoritative documentation. Define why the
dependency is needed, upgrade order, lockfile or generated-file effects,
fallback, and version-specific verification. Do not add a dependency when an
existing supported mechanism is enough.

### Performance or capacity

Trigger: the work changes a hot path, query count, memory ownership, network
traffic, payload size, fan-out, startup time, or a stated service objective.

Define the metric, baseline source, expected bound, measurement point, data
shape, and failure threshold. Do not use “fast” or “scalable” without a measure.

### User interface

Trigger: a user-visible screen, command, form, interaction, accessibility
state, or navigation path changes.

Define states for loading, empty, success, error, permission denial, retry, and
responsive or accessibility behavior when material. Keep visual polish out of
the plan unless it is part of acceptance.

### Operations and rollout

Trigger: deployment order, feature control, migration, external integration,
or production recovery matters.

Define preconditions, rollout stages, monitoring, abort threshold, rollback or
forward-recovery path, cleanup, and ownership. State when rollback is unsafe.

## Check cross-cutting effects

Before work-unit design, scan the selected approach for effects on:

- callers and downstream consumers;
- stored and in-flight data;
- background and scheduled work;
- observability and support tools;
- documentation and examples;
- installation, packaging, or generated output; and
- tests that encode the old contract.

Add a plan item only when the effect is real. If an important consumer cannot
be inspected, record the uncertainty and its owner.

## Design result

The technical design is ready for decomposition when:

- current and target flows are clear;
- each material boundary has one target contract;
- load-bearing choices have reasons and consequences;
- risk-triggered decisions are explicit;
- no product decision is hidden inside the approach; and
- the selected approach can be divided into coherent, verifiable work units.
