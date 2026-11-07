# Data foundation rules

Load this file for `focus:data`, `focus:code`, or when a finding concerns data
shape, invariants, normalization, serialization, or error values. These rules
favor explicit data contracts before processes or effects. A struct, type, or
wrapper is not automatically better than a map, tuple, or list.

## `data-access-shape-mismatch` version 1

- **Use when:** One data structure causes repeated scans, conversion, copying,
  or unclear identity for the package's real access patterns.
- **Detect:** Trace creation, reads, updates, ordering, and lookup frequency.
  Measure before making a performance claim.
- **Finding:** One data shape has a demonstrated mismatch with its required
  access pattern.
- **Fix:** Select the smallest standard structure that matches the access
  pattern and keep conversion at the trust boundary.
- **Protect:** Ordering, duplicate handling, identity, serialization, and memory
  limits.
- **Verify:** Contract tests and comparable workload measurements pass.
- **Judgment stop:** Workload, ordering, or compatibility needs are unknown.
- **Batch key:** Data owner and access pattern.

## `data-invariant-gap` version 1

- **Use when:** Related values travel as loose data and several callers repeat
  validation or can construct an invalid combination.
- **Detect:** Trace constructors, updates, pattern matches, specs, and invalid
  inputs across each boundary.
- **Finding:** One domain invariant has no single data owner.
- **Fix:** Give construction and update to one ordinary function, struct, or
  opaque type only when it makes the invariant explicit.
- **Protect:** Accepted inputs, error results, serialization, and extension
  contracts.
- **Verify:** Valid and invalid construction plus all update paths pass.
- **Judgment stop:** The invariant or public representation is not established.
- **Batch key:** Invariant and data owner.

## `normalization-owner-gap` version 1

- **Use when:** Several layers normalize the same value or accept different
  normalized forms.
- **Detect:** Trace one valid and invalid value from external input through the
  functional core and storage or wire output.
- **Finding:** One normalization rule has several owners or no clear trust
  boundary.
- **Fix:** Normalize once at the earliest owned trust boundary and pass the
  canonical form internally.
- **Protect:** Accepted aliases, error locations, defaults, and round trips.
- **Verify:** Direct, nested, and already-normalized cases pass through every
  public entry point.
- **Judgment stop:** Different layers intentionally own different policies.
- **Batch key:** Normalized concept and trust boundary.

## `boundary-key-shape-drift` version 1

- **Use when:** Atom and string keys, missing and `nil`, maps and structs, or
  strict and loose equality have different meanings across boundaries.
- **Detect:** Build a small matrix for direct and nested input forms and trace
  the actual result at each boundary.
- **Finding:** One supported key or absence rule changes meaning between layers.
- **Fix:** Define one boundary conversion and one internal representation.
- **Protect:** Compatibility, unknown-key policy, defaults, and serialization.
- **Verify:** The full key and absence matrix passes.
- **Judgment stop:** The accepted external forms or compatibility period is
  unknown.
- **Batch key:** Boundary and key policy.

## `data-roundtrip-loss` version 1

- **Use when:** Encode/decode, store/load, or normalize/render should preserve a
  documented value but loses or changes it.
- **Detect:** Compare representative and edge values through the complete
  round trip, including nested and custom implementations.
- **Finding:** One required value distinction is lost, rejected, or changed.
- **Fix:** Correct the smallest owning conversion or document an intentional
  lossy boundary.
- **Protect:** Wire compatibility, defaults, error classification, and version
  handling.
- **Verify:** Round-trip examples, invalid inputs, and compatibility fixtures
  pass.
- **Judgment stop:** Loss is intentional or the wire contract is not settled.
- **Batch key:** Codec boundary and lost distinction.

## `error-contract-drift` version 1

- **Use when:** The same failure has different tuple, exception, map, retry, or
  message meanings across layers.
- **Detect:** Trace expected domain errors and unexpected faults from source to
  each public and observable result.
- **Finding:** One error class changes meaning or loses required context.
- **Fix:** Give classification and public mapping to one boundary while keeping
  internal causes available where required.
- **Protect:** Stable messages, retryability, exception behavior, telemetry, and
  caller pattern matches.
- **Verify:** Success, each domain error, and one unexpected fault pass through
  the public boundary.
- **Judgment stop:** The public error policy or compatibility need is unknown.
- **Batch key:** Error class and public boundary.

## `internal-wire-data-conflation` version 1

- **Use when:** One structure serves as mutable internal representation and a
  stable external, stored, or wire contract.
- **Detect:** Compare internal access needs with public fields, versioning,
  encoding, and downstream consumers.
- **Finding:** Internal change pressure can accidentally change a stable
  boundary, or boundary constraints distort the functional core.
- **Fix:** Add one explicit conversion only when the two contracts differ.
- **Protect:** Wire compatibility, performance, defaults, and public types.
- **Verify:** Internal behavior and boundary compatibility tests pass.
- **Judgment stop:** The structure is intentionally the public contract or the
  separation adds no distinct rule.
- **Batch key:** Internal owner and external contract.

## `invalid-state-encoding` version 1

- **Use when:** Several optional fields, tags, or booleans permit combinations
  that the domain rejects later.
- **Detect:** Enumerate reachable combinations and trace where each invalid
  state is created or rejected.
- **Finding:** One recurring invalid combination is representable without a
  useful compatibility reason.
- **Fix:** Use the smallest tagged form, constructor, or state-specific data
  type that removes the invalid combination.
- **Protect:** Stored data, public input, upgrade paths, and error messages.
- **Verify:** Valid states remain constructible and invalid transitions fail at
  the owning boundary.
- **Judgment stop:** The state is required for migration, partial input, or an
  external protocol.
- **Batch key:** State model and constructor.

## `option-flag-complexity` version 1

- **Use when:** Boolean or loosely typed options select several distinct modes
  and create interacting branches.
- **Detect:** Build the reachable option matrix and identify combinations with
  different contracts.
- **Finding:** One option set hides distinct operations or permits unsupported
  combinations.
- **Fix:** Use named operations or a tagged option when it reduces real branch
  and caller complexity.
- **Protect:** Defaults, compatibility, documentation, and all supported modes.
- **Verify:** The option matrix and public examples pass.
- **Judgment stop:** The options are independent, stable, and clearer than
  separate operations.
- **Batch key:** Public operation and option matrix.

## `wrapper-without-contract` version 1

- **Use when:** A module or function only renames calls, copies data, or maps
  identical results and has one concrete use.
- **Detect:** Trace callers, public documentation, extension points, fault
  boundaries, and test ownership.
- **Finding:** One wrapper adds navigation or change cost without owning a
  domain, compatibility, effect, or test contract.
- **Fix:** Remove the wrapper or move the rule to the existing owner.
- **Protect:** Public API, dependency direction, error mapping, and future work
  already committed by project policy.
- **Verify:** Callers and package checks pass with fewer indirections.
- **Judgment stop:** The wrapper owns a supported boundary or external consumer.
- **Batch key:** Wrapper and delegated owner.

## `unsafe-compile-time-data` version 1

- **Use when:** A macro or module attribute stores caller-supplied values in
  generated module data.
- **Detect:** Distinguish caller AST from the evaluated term. Probe nested maps,
  keys, tuples, structs, proper and improper lists, captures, PIDs, ports, and
  references under supported Elixir versions.
- **Finding:** One unsupported or runtime-only term is stored, rejected at the
  wrong location, or bypasses the declared static-data contract.
- **Fix:** Validate the evaluated term, escape supported terms, and report the
  declaration source.
- **Protect:** Supported compile-time values, error location, generated code,
  and version compatibility.
- **Verify:** Compile minimal accepted and rejected declarations.
- **Judgment stop:** The static-data contract or supported Elixir behavior is
  not established.
- **Batch key:** Macro declaration and stored term contract.

## `observable-secret-leak` version 1

- **Use when:** Errors, logs, telemetry, process status, or serialized output can
  contain sensitive values.
- **Detect:** Use a distinctive marker under atom and string keys in nested
  maps, keyword and mixed lists, improper lists, tuples, structs, and
  exceptions. Inspect every observable output.
- **Finding:** One reachable observable boundary emits the marker or unsafe raw
  text.
- **Fix:** Sanitize before summary or output while retaining required safe
  fields and classification.
- **Protect:** Output shape, diagnostics, grouping, stack information policy,
  and performance limits.
- **Verify:** The marker is absent from every boundary and safe fields remain.
- **Judgment stop:** Sensitivity or required diagnostic retention is undefined.
- **Batch key:** Observable boundary and sanitizer profile.

## `broad-exception-recovery` version 1

- **Use when:** `rescue`, `catch`, or a fallback converts unrelated faults into
  one normal domain result.
- **Detect:** Trace expected errors and representative programmer, process, and
  external faults through the recovery path.
- **Finding:** One broad recovery path hides a fault or applies an unsafe retry
  or fallback policy.
- **Fix:** Match only the owned failure class or move recovery to the boundary
  that owns it.
- **Protect:** Domain errors, crash semantics, cleanup, telemetry, and retry
  behavior.
- **Verify:** Expected errors retain their result and unexpected faults keep the
  required failure behavior.
- **Judgment stop:** The fault containment boundary or recovery policy is not
  established.
- **Batch key:** Recovery boundary and failure class.
