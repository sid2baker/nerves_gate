# OTP layering and process rules

Load this file for `focus:otp`, `focus:architecture`, or when code uses
processes, supervision, tasks, timers, monitors, persistence, or external
effects. The review order follows the public layer model in
[Designing Elixir Systems with OTP](https://pragprog.com/titles/jgotp/designing-elixir-systems-with-otp/):
data, functional core, tests, boundaries, lifecycle, and workers. Not every
package needs every layer. Add a layer only for a demonstrated contract.

These rules are judgment-first. A process is not a defect. A pure function is
not automatically better when serialization, isolation, concurrency, lifecycle,
or resource ownership is required.

## `data-before-process-gap` version 1

- **Use when:** A process owns domain state whose shape, invariants, and pure
  transitions are not established outside process machinery.
- **Detect:** Trace input data, state, transitions, replies, effects, and invalid
  states without assuming that the process is the data model.
- **Finding:** One process layer hides an unresolved data contract and makes
  behavior hard to compose or test without starting the process.
- **Fix:** Establish the smallest data type and pure transition first, then keep
  only required runtime ownership in the process.
- **Protect:** Message and API behavior, ordering, time, persistence, and
  observability.
- **Verify:** Pure transition tests and boundary tests produce equivalent
  results and effects.
- **Judgment stop:** Process identity or time is part of the domain contract.
- **Batch key:** Process owner and hidden data contract.

## `functional-core-gap` version 1

- **Use when:** Validation, calculation, and domain transition are interleaved
  with messaging, storage, time, or network effects.
- **Detect:** Trace whether the same input and explicit state can produce a
  result and effect description without runtime machinery.
- **Finding:** One deterministic rule has no composable functional owner.
- **Fix:** Move the deterministic rule to an ordinary function and leave effect
  execution at the boundary.
- **Protect:** Effect order, error mapping, state transition, and performance.
- **Verify:** Core tests and end-to-end boundary tests agree.
- **Judgment stop:** The result depends on process identity, real time, or an
  inseparable external transaction.
- **Batch key:** Domain rule and effect boundary.

## `process-without-runtime-need` version 1

- **Use when:** A process appears to wrap data or functions without required
  isolation, concurrency, serialization, lifecycle, or resource ownership.
- **Detect:** Name the runtime guarantee supplied by the process and search all
  callers for dependence on it.
- **Finding:** One process boundary has measurable complexity but no supported
  runtime responsibility.
- **Fix:** Use ordinary data and functions, or retain the process and document
  its real runtime contract.
- **Protect:** Ordering, shared ownership, failure isolation, and public API.
- **Verify:** Callers and lifecycle tests pass without the unnecessary boundary.
- **Judgment stop:** External consumers or deployment policy require the
  process.
- **Batch key:** Process and claimed runtime guarantee.

## `process-machinery-leak` version 1

- **Use when:** Public callers must know server names, message forms, PIDs,
  monitor references, or OTP callback details for an ordinary operation.
- **Detect:** Follow a caller from its domain intent to the process interaction.
- **Finding:** One public contract exposes machinery that the owning boundary
  can contain.
- **Fix:** Add or repair a thin boundary API that keeps domain data and errors
  explicit.
- **Protect:** Advanced supported access, ordering, timeouts, and observability.
- **Verify:** Callers use the boundary and boundary tests exercise the real
  process.
- **Judgment stop:** The process protocol is intentionally public.
- **Batch key:** Public operation and process boundary.

## `boundary-api-gap` version 1

- **Use when:** A process or external service has no stable API that owns input,
  output, timeout, and error meaning.
- **Detect:** Compare all direct calls, casts, messages, and effect adapters.
- **Finding:** One runtime boundary has several caller-defined protocols.
- **Fix:** Give the smallest supported protocol to one boundary module.
- **Protect:** Existing caller behavior, timeout policy, compatibility, and
  extension points.
- **Verify:** Minimal and failure-path callers pass through the boundary.
- **Judgment stop:** The intended public boundary is not established.
- **Batch key:** Runtime service and caller protocol.

## `call-cast-backpressure-gap` version 1

- **Use when:** A cast, send, or fire-and-forget task accepts work that needs
  admission, ordering, failure, or capacity feedback.
- **Detect:** Trace what the caller must know, queue growth, overload behavior,
  and late failure handling.
- **Finding:** One asynchronous API cannot provide required backpressure or
  acceptance evidence.
- **Fix:** Use a call, explicit admission result, bounded queue, demand protocol,
  or documented loss policy that owns overload.
- **Protect:** Throughput, ordering, timeout behavior, and failure isolation.
- **Verify:** Capacity, rejection, timeout, and recovery scenarios pass.
- **Judgment stop:** Loss and unbounded delay are accepted product policy.
- **Batch key:** Admission boundary and overload policy.

## `lifecycle-owner-gap` version 1

- **Use when:** No single owner starts, stops, restarts, or cleans one runtime
  resource.
- **Detect:** Trace normal start, failed start, owner death, worker death,
  restart, cancellation, and shutdown.
- **Finding:** One lifecycle transition can be missed, repeated, or performed by
  several owners.
- **Fix:** Give lifecycle state and cleanup to one process or supervisor boundary.
- **Protect:** Restart strategy, public availability, data durability, and
  observability.
- **Verify:** Every lifecycle event has one outcome under deterministic tests.
- **Judgment stop:** Required ownership or restart policy is unknown.
- **Batch key:** Resource and lifecycle owner.

## `state-transition-multi-owner` version 1

- **Use when:** Several processes or callbacks can apply the same logical state
  transition or emit its event.
- **Detect:** Trace success, retry, duplicate request, stale message, and owner
  death through every writer.
- **Finding:** One transition can occur twice, out of order, or without matching
  cleanup.
- **Fix:** Route transition, cleanup, and event emission through one owner.
- **Protect:** Idempotency, event count and order, cursors, and retries.
- **Verify:** Duplicate and stale cases produce one owned result.
- **Judgment stop:** Multi-writer semantics are deliberate and specified.
- **Batch key:** State transition and writer set.

## `unsupervised-process` version 1

- **Use when:** A long-lived process or task is started outside an established
  lifecycle owner.
- **Detect:** Trace links, monitors, registration, restart, shutdown, and release
  startup.
- **Finding:** One required runtime process can leak, disappear silently, or
  outlive its owner.
- **Fix:** Place it under the correct supervisor or give it explicit bounded
  ownership.
- **Protect:** Failure isolation, restart intensity, startup order, and dynamic
  instance behavior.
- **Verify:** Owner and child death plus application shutdown behave as required.
- **Judgment stop:** The process is intentionally detached or short-lived.
- **Batch key:** Process and lifecycle owner.

## `task-owner-gap` version 1

- **Use when:** Spawned tasks have unclear supervision, result collection,
  cancellation, timeout, or failure handling.
- **Detect:** Trace task start through every completion and owner-exit order.
- **Finding:** One task result or failure can be lost, leak work, or affect the
  wrong owner.
- **Fix:** Use a supervised task and one result owner with explicit cancellation.
- **Protect:** Concurrency, timeout, links or monitors, and error reporting.
- **Verify:** Complete-before-wait, complete-during-wait, timeout, task crash, and
  owner crash cases pass.
- **Judgment stop:** Detached best-effort work is an accepted contract.
- **Batch key:** Task family and result owner.

## `timer-monitor-cleanup-gap` version 1

- **Use when:** Timers or monitors are created, replaced, or cancelled across
  several paths.
- **Detect:** Trace normal completion, replacement, cancellation, target death,
  late messages, and owner shutdown.
- **Finding:** One timer or monitor can remain stale, fire twice, or leak state.
- **Fix:** Give creation and cleanup to the lifecycle transition owner and make
  late messages harmless.
- **Protect:** Deadlines, message order, event count, and restart behavior.
- **Verify:** Deterministic barriers exercise every cleanup order.
- **Judgment stop:** Late or duplicate delivery is part of the protocol.
- **Batch key:** Timer or monitor purpose and owner.

## `blocking-server-callback` version 1

- **Use when:** A GenServer or similar serialized owner performs long CPU work,
  blocking I/O, or an external call inside its callback.
- **Detect:** Measure callback time and trace mailbox delay, timeout, and failure
  behavior under a relevant workload.
- **Finding:** One owned callback blocks unrelated required progress.
- **Fix:** Move work to a supervised worker or redesign ownership while keeping
  state transitions in one owner.
- **Protect:** Ordering, state consistency, cancellation, and overload behavior.
- **Verify:** Functional behavior and measured responsiveness improve under the
  same workload.
- **Judgment stop:** Serialization of the full operation is required.
- **Batch key:** Server callback and workload.

## `mailbox-pressure-gap` version 1

- **Use when:** Producers can outpace one process and no capacity or loss policy
  exists.
- **Detect:** Measure arrival, service rate, queue growth, message size, and
  overload recovery.
- **Finding:** One mailbox can grow beyond the supported bound or delay critical
  work indefinitely.
- **Fix:** Add backpressure, demand, bounded admission, partitioning, or an
  explicit discard policy at the owner.
- **Protect:** Ordering, durability, fairness, and failure handling.
- **Verify:** Bounded overload and recovery tests meet declared limits.
- **Judgment stop:** Capacity and loss policy are product decisions without an
  owner.
- **Batch key:** Producer-consumer boundary and capacity policy.

## `oversized-process-message` version 1

- **Use when:** Messages copy or retain much more data than the receiver needs.
- **Detect:** Inspect message shape, heap copying, retained references, fan-out,
  and receiver access.
- **Finding:** One message has a demonstrated memory or coupling cost that a
  smaller contract avoids.
- **Fix:** Send the required value or stable reference while preserving
  ownership and lifetime.
- **Protect:** Snapshot semantics, locality, failure behavior, and data lifetime.
- **Verify:** Behavior passes and memory or message measurements improve.
- **Judgment stop:** The full immutable snapshot is required or no cost is shown.
- **Batch key:** Message protocol and receiver.

## `derivable-process-state` version 1

- **Use when:** Process state stores duplicate or derivable values that can
  disagree after updates or recovery.
- **Detect:** Trace every writer, restore path, and read of the duplicated value.
- **Finding:** One stored derivative can become stale or increases transition
  cost without a measured need.
- **Fix:** Derive on read, or centralize cache invalidation when measurement
  justifies storage.
- **Protect:** Performance, recovery, serialization, and upgrade behavior.
- **Verify:** Update and restore paths remain correct; performance claims use
  comparable measurements.
- **Judgment stop:** The value is an intentional cache with an owned policy.
- **Batch key:** State owner and derived value.

## `persistence-core-coupling` version 1

- **Use when:** Domain functions depend directly on storage processes, schemas,
  transactions, or persistence-specific errors.
- **Detect:** Trace whether the same domain transition can run from explicit data
  and return an effect or result independent of storage.
- **Finding:** One persistence boundary controls or distorts a functional domain
  contract.
- **Fix:** Keep domain transition pure and perform load/store in one boundary
  service when the separation is real.
- **Protect:** Transaction scope, optimistic concurrency, durability, and error
  mapping.
- **Verify:** Core and persistence boundary tests pass, including conflicts and
  failures.
- **Judgment stop:** The transaction itself is the domain operation.
- **Batch key:** Domain transition and persistence boundary.

## `external-effect-idempotency-gap` version 1

- **Use when:** A retried, duplicated, or recovered operation can repeat an
  external side effect.
- **Detect:** Trace effect identity, persistence, acknowledgement, retry, timeout,
  crash, and replay order.
- **Finding:** One supported retry path can duplicate or lose an effect contrary
  to the contract.
- **Fix:** Add an idempotency key, effect ledger, conditional write, or explicit
  at-most-once or at-least-once policy at the boundary.
- **Protect:** Throughput, durability, ordering, and provider semantics.
- **Verify:** Crash-before, crash-during, timeout, duplicate, and replay cases
  meet the declared guarantee.
- **Judgment stop:** Delivery semantics are not selected or provider support is
  unknown.
- **Batch key:** External effect and delivery identity.

## `fault-domain-mismatch` version 1

- **Use when:** Unrelated work shares one crash boundary, or tightly coupled work
  is split across boundaries that cannot recover consistently.
- **Detect:** Trace failure propagation, restart scope, retained state, and caller
  impact for representative faults.
- **Finding:** One process or supervisor boundary restarts too much, too little,
  or in an unsafe order.
- **Fix:** Align process and supervision boundaries with the required fault and
  recovery unit.
- **Protect:** Availability, state consistency, restart intensity, and dependent
  services.
- **Verify:** Fault injection shows the intended restart and recovery scope.
- **Judgment stop:** Availability and recovery requirements are unknown.
- **Batch key:** Fault unit and supervisor boundary.

## `retry-policy-gap` version 1

- **Use when:** Retried work has no clear owner, bound, delay, classification, or
  terminal result.
- **Detect:** Trace retryable and permanent failures, attempt state, backoff,
  cancellation, shutdown, and duplicate effects.
- **Finding:** One retry path can loop, amplify load, hide failure, or repeat an
  unsafe effect.
- **Fix:** Give retry classification and bounded policy to one boundary.
- **Protect:** Latency, overload, idempotency, observability, and caller errors.
- **Verify:** Retryable, permanent, exhausted, cancelled, and recovered cases
  pass.
- **Judgment stop:** Product retry limits or delivery guarantees are unknown.
- **Batch key:** Operation and retry owner.

## `shutdown-cleanup-gap` version 1

- **Use when:** Shutdown can leave tasks, handles, registrations, timers, files,
  or external leases active.
- **Detect:** Trace normal stop, supervisor shutdown, timeout, brutal kill, and
  owner crash.
- **Finding:** One required resource lacks cleanup or safe expiry behavior.
- **Fix:** Put cleanup in the owner lifecycle and make repeated cleanup safe.
- **Protect:** Shutdown deadlines, restart, durability, and external leases.
- **Verify:** Each supported shutdown path releases or safely expires resources.
- **Judgment stop:** Cleanup is impossible or intentionally delegated without a
  documented lease policy.
- **Batch key:** Resource and shutdown owner.

## `supervision-policy-mismatch` version 1

- **Use when:** Restart type, child order, intensity, or dynamic ownership does
  not match the component's recovery contract.
- **Detect:** Trace normal completion and representative transient and permanent
  failures through the supervision tree.
- **Finding:** One child is restarted, retained, or terminated contrary to its
  supported lifecycle.
- **Fix:** Correct the smallest child specification or supervision boundary.
- **Protect:** Availability, dependency order, state restore, and shutdown.
- **Verify:** Deterministic failure cases show the required supervisor outcome.
- **Judgment stop:** Recovery policy is not established.
- **Batch key:** Supervisor and child lifecycle.

## `layer-dependency-inversion` version 1

- **Use when:** Data or functional-core modules depend on process, persistence,
  transport, framework, or composition layers without an explicit domain need.
- **Detect:** Trace compile and runtime edges together with the contract each edge
  serves.
- **Finding:** One lower layer imports a higher-layer mechanism and loses reuse,
  testability, or ownership clarity.
- **Fix:** Move the effect to its boundary, pass data or a narrow function, or
  use an established inversion contract.
- **Protect:** Public API, performance, compile behavior, and extension points.
- **Verify:** Dependency checks and affected contract tests pass.
- **Judgment stop:** The layer model or correct owner is not established.
- **Batch key:** Dependency edge and layer owner.
