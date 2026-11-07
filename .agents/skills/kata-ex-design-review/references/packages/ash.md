# Ash context review lenses

Use these lenses for the installed Ash and Phoenix versions. Read the local
dependency guides before making claims about exact options or lifecycle order.
The review goal is a sound context contract, not maximum use of Ash features.

## Domain and context ownership

- A public context module, Domain code interface, or resource code interface owns
  product vocabulary and stable operations.
- The Ash Domain groups resources and supplies a framework interface. It does not
  automatically make every resource action a product API.
- A resource owns facts and operations that center on that resource.
- Cross-resource orchestration belongs in one named action, a context operation,
  or a workflow tool selected for the required transaction and recovery model.
- A persistence helper, sometimes named `Store`, is useful when it hides a real
  persistence port or stable translation. It is harmful when it reconstructs
  action policy, accepts broad maps, or exposes Ash records and errors to all
  callers.
- Keep one owner for each configuration key, state machine, audit event, and
  copied fact. Derive facts from their owner instead of caching them in a second
  resource without a synchronization contract.

## Actions and code interfaces

Ash actions are the main resource interaction boundary. Review whether actions:

- Use names that describe intent instead of one broad CRUD path.
- Accept only caller-controlled inputs required by that operation.
- Use private arguments, context, or changes for system-controlled values.
- Contain the relevant filters, preparations, changes, validations, and
  transaction intent.
- Return a useful result without requiring callers to know changeset/query steps.
- Have code interfaces or context delegates that keep callers on the named action.
- Avoid unused generic actions that expand mutation capability.

Default CRUD actions can be suitable for simple child resources. They are a risk
when the context has lifecycle rules, event-sourced projections, ownership checks,
or audit requirements that direct mutation can bypass.

Do not move pure calculation, canonicalization, serialization, or deterministic
state reduction into an Ash action only for uniformity. Keep the action as the
effect and policy boundary and call the pure code from it.

## Validation and durable invariants

Compare four layers for each invariant:

1. Public input validation and error vocabulary.
2. Ash action validations and changes.
3. Resource identities and attribute constraints.
4. Database indexes, foreign keys, null rules, check constraints, and defaults.

Use the earliest layer for useful errors and the database for final durable
enforcement. A read-then-create check alone does not protect uniqueness under
concurrency. Map an expected identity or stale-record conflict to the context's
documented error without converting all Ash errors into one storage error.

Review:

- `allow_nil?`, public and writable flags, sensitive fields, defaults, and types.
- Identity names and whether the generated database constraint exists.
- Partial unique indexes and conditional invariants.
- Foreign-key delete behavior and whether it matches lifecycle ownership.
- State-specific constraints, such as required lease data for a leased record.
- String length, byte length, enum, and normalization consistency across layers.
- Resource snapshots and migration drift for every supported data layer.

Validation does not replace authorization. `sensitive? true` changes display
behavior; it is not an access policy.

## Authorization and actors

Trace actor or scope data from Phoenix entry point to Ash action. Check:

- Authentication and authorization are not confused.
- Every route, API, channel, job, and internal entry point enforces the intended
  rule.
- Policies cover each exposed action and sensitive field where required.
- Ownership filters use the actor and cannot be supplied by an untrusted caller.
- Internal maintenance operations that use `authorize?: false` are private,
  narrow, and do not accept untrusted data without equivalent checks.
- A public struct or request scope is not treated as proof of authentication only
  because a caller can construct it.
- Policy tests include allowed, forbidden, missing-actor, and cross-owner cases.

When Phoenix or AshAuthentication requires a concrete resource module, document
that requirement. Expose only the actions and fields the framework needs.

## Transactions, hooks, and external effects

Identify the exact transaction boundary for every multi-write operation. Confirm
that a failure cannot leave a product state that contradicts its durable status.

For the installed Ash version, verify lifecycle hook placement in its local docs.
As a review rule:

- Keep database work that must commit together inside one transaction.
- Keep transaction work short. Do not hold a database connection during an
  unbounded or long external request.
- Put external effects outside the database transaction unless the product has a
  deliberate compensation or idempotency design.
- Do not call an operation atomic only because each individual action is
  transactional.
- Check notification and signal timing relative to commit and rollback.
- Verify what cleanup hooks run on failure, not only on success.
- Use relationship management when related records are part of action input and
  that matches the installed framework guidance.
- Use Reactor, jobs, or other workflow tools only when the required compensation,
  durability, or orchestration exceeds a clear action/context operation.

Test a failure after each meaningful write or effect boundary when partial state
would matter.

## Concurrency and atomicity

State the concurrency contract before selecting a mechanism. Inspect:

- Upsert identity and fields.
- Atomic update support and whether custom changes prevent atomic execution.
- Optimistic locking for stale writes when appropriate.
- Row or advisory locks for serialized durable transitions.
- Lease ownership, expiry, fencing token or generation, and stale completion.
- Retry policy, delay, maximum attempts, and terminal failure.
- Idempotency keys and duplicate external effects.
- Adapter differences in locking and isolation.

Do not use a VM-local lock for a cross-node or database invariant. Do not add a
database lock when an atomic constraint or update is sufficient.

## Relationships, queries, and returned data

Review whether relationships express ownership or only query convenience. Check:

- Relationship foreign keys, destination filters, and delete behavior.
- Read actions used through relationships and their authorization policies.
- Loads performed by the context versus required from every caller.
- N+1 queries, repeated loads, and unbounded list actions.
- Pagination, deterministic ordering, and maximum limits.
- Calculations and aggregates that hide query or authorization cost.
- Partially loaded resource structs crossing the context boundary.
- Stable view structs or maps when the public contract must not expose Ash load
  state or private fields.

Do not add a view struct automatically. Add one when it protects a stable public
contract or prevents persistence details from leaking.

## Phoenix adapters

Controllers, LiveViews, plugs, channels, and API handlers are adapters. Review
whether they:

- Normalize transport input and call one context operation.
- Pass the actor or scope explicitly.
- Translate stable context errors to transport results in one place.
- Avoid direct Ash queries or changesets that bypass named operations.
- Avoid copying durable workflow state into socket state as another authority.
- Apply global gates to browser, JSON API, GraphQL, channel, and background paths.
- Move long work out of request or LiveView callbacks when latency or failure
  isolation requires it.
- Avoid logging secrets, tokens, raw changesets, or policy details.

Keep UI presentation state in the adapter. Keep business transitions and durable
state in the context.

## Resource and boundary exposure

For every exported child module, record why callers need the concrete module.
Common valid reasons include a public value type, framework macro, resource needed
by a framework integration, or an OTP child that the application must supervise.

Review an exposed resource for:

- Generic mutation actions that bypass the intended public API.
- Public fields that reveal storage or secret data.
- Direct callers that build queries and depend on internal attributes.
- Ash Domain or persistence-helper modules used outside their intended scope.
- Codecs, adapters, and clients that should remain internal.

When a framework requires the module but not broad mutation, keep the module
available and narrow its actions, policies, and public attributes.

## Error contracts and observability

- Keep validation, not-found, forbidden, conflict, stale, unavailable, and
  internal faults distinct when callers can act on the difference.
- Translate expected Ash errors at one boundary.
- Do not rescue every exception into `:storage_error`; that hides defects and
  weakens OTP failure reporting.
- Sanitize Ash changesets, policy errors, exceptions, logs, and telemetry before
  they cross a public boundary.
- Include safe operation, resource, status, duration, and retry metadata where it
  helps operations. Do not include credentials or user content by default.

## Tests and coverage

Prefer these test layers:

1. Pure unit tests for normalization and transitions.
2. Ash action tests for changes, validations, policies, and errors.
3. Database integration tests for constraints, transactions, and concurrency.
4. Phoenix adapter tests for authentication, authorization, and error mapping.
5. OTP lifecycle tests for recovery, cleanup, retry, and backpressure.

Review test setup for the installed data layer. For example, transactional SQL
tests need the repository's DataCase or sandbox setup, and Ash task behavior must
be compatible with that setup.

Important cases include:

- Exact boundary values and malformed options.
- Expected identity conflicts and stale writes.
- Concurrent create, update, delete, and any domain-specific lease or rotation
  operations.
- Rollback after an intermediate write.
- Forbidden direct actions and cross-owner access.
- Adapter parity when the application supports more than one database.
- Full lifecycle sequences, including retry and terminal failure.
- Real production wiring for at least one success and one failure path.

Generated DSL coverage is not the target. Prioritize custom actions, changes,
validations, policies, facade branches, adapters, and workers. High line coverage
does not prove concurrency or authorization contracts.
