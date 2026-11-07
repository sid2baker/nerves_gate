# Review lenses

## Elixir code and data

- Use pattern matching and function clauses when they make cases explicit.
  Do not replace a clear `case` or `with` just to follow a style rule.
- Look for deep branching, repeated normalization, broad option maps, boolean
  switches, and error tuples with different meanings at different layers.
- Prefer standard library functions when input, error, ordering, and lazy/eager
  behavior are equivalent. Check list construction and repeated enumeration.
- Assess whether structs encode useful invariants, or merely copy another type.
  Keep internal data and external serialization contracts distinct where needed.
- Compare public types/specs, constructor and runtime validation, normalization,
  serialization/deserialization, and docs/examples as one contract. Trace the
  same valid and invalid values through each boundary. Check ranges, key forms,
  collisions, missing versus `nil`, custom implementations, and round-trip
  behavior. Distinguish an intentional wire representation from an accidental
  loss or rejection. Tests and docs can both repeat the same wrong assumption.
- Use macros, protocols, and behaviours for concrete needs. Compare a custom
  DSL or generic engine with plain functions before recommending either design.
- Match control flow to intent: transformations, dependent fallible steps,
  independent validation, or state accumulation. Do not force all forms into
  `with`, pipelines, or function clauses.
- Check missing versus `nil` values, atom versus string keys, map versus struct
  access, and strict versus loose equality before replacing a helper or guard.

## Compile-time terms — when macros store caller values

- Distinguish caller AST from the evaluated term that generated module data will
  store. Use `Macro.escape/1` on that term first; handle escape failures at the
  declaration's source line. Escape support does not prove that a value meets
  the storage contract: a PID can escape but still violate a static-data rule.
- For static data, inspect the escaped form with one `Macro.prewalk/3` traversal
  for PID, port, and reference literals that escape leaves in the tree. Preserve
  nodes while accumulating the result. Let escape reject unsupported terms;
  avoid a second custom recursion over raw Erlang containers unless required.
- Probe direct and nested values in maps (keys and values), tuples, structs, and
  proper/improper lists. Check allowed remote captures and rejected anonymous
  functions under the supported Elixir versions. Do not replace this check with
  `Macro.quoted_literal?/1`: it tests quoted literals and can reject supported
  remote captures or improper lists. Compile a minimal module to confirm the
  accepted value and declaration-line error, not only the helper's return.
  See the official [Macro documentation](https://hexdocs.pm/elixir/Macro.html).

## Sanitizers — when data crosses an observable boundary

- Use distinctive secret markers under sensitive atom and string keys. Probe
  maps, keyword lists, mixed lists, improper lists (head and tail), tuples,
  structs, and exceptions, both directly and nested. A key-value tuple in a
  mixed list must not bypass a required key-based redaction rule through the
  general tuple clause. Check each output profile and its required shape.
- Exercise depth, size, truncation, and unsupported-value fallback paths.
  Raw `inspect/2` previews or exception messages can expose secrets even when
  the main recursive path is safe. Sanitize before summarizing, or use a
  content-free type marker when a safe preview is not part of the contract.
- Verify the actual outputs: public error maps and serialized data, captured
  Logger output, telemetry metadata, and process status where present. Assert
  that the marker is absent and required non-sensitive fields remain. Inspect
  grouped/nested exceptions for source paths, stack frames, dependency text,
  stable public messages, and retained error classification/retryability.
  A private sanitizer test alone does not prove these boundaries use it.

## OTP ownership and failure

- Identify who owns each process, task, monitor, timer, ETS table, and live handle.
  Check restart behavior, cancellation, shutdown, and cleanup on every exit path.
- Give each lifecycle transition one owner for state changes, monitor/timer
  cleanup, and event emission. Trace unsubscribe, target death, stale-target
  replacement, retry, and shutdown through that owner where applicable. Separate
  removal of an entry from detachment of its live target; they can have distinct
  contracts. Check idempotency, event count/order, cursor retention, and stale
  messages. A shared event helper alone does not give the transition one owner.
  Use deterministic call barriers, suspension, or monitors to check detach before
  attach and absence of duplicate events under the promised ordering.
- Ask why each process boundary exists: isolation, concurrency, serialization,
  lifecycle, or resource ownership. A module does not need its own process.
- Check whether custom registries, restart loops, routing, or task control repeat
  a verified OTP guarantee. Preserve additional guarantees that OTP does not own.
- Check mailbox growth, blocking callbacks, timeout semantics, late messages,
  links versus monitors, and supervision order where the code uses them.
- Check that process interaction has a clear public interface. Look for task
  closures or messages that carry much more data than the receiver needs.
- Separate expected domain errors from process faults. Neither blanket rescue
  nor “let it crash” replaces a defined error and recovery contract.
- Distinguish local state replacement, durable storage, and external effects.
  More phases do not by themselves provide rollback or exactly-once delivery.

## Abstractions and package boundaries

- Trace wrappers that only rename calls, repeated data conversions, duplicated
  state, broad callback sets, and generic frameworks used by one concrete path.
- Keep an abstraction when it carries a real domain rule, fault boundary,
  extension contract, or useful test boundary. Do not inline a named concept
  merely to remove a file.
- Search for an existing owner before extracting a shared helper. Compare the
  total code and call path after extraction, including wrappers and error mapping.
  Similar syntax with different contracts can be clearer as local code.
- Check whether optional persistence, distribution, or plugins impose costs on
  basic local use. Name the exact cost and the requirement behind it.
- Review composition: does wrapping or combining operations preserve results,
  errors, effects, order, and resource ownership?
- Keep public concepts in the package that owns them. Inspect consumers before
  recommending a package split or a change in dependency direction.
- Check compile-time coupling from macros, struct expansion, and configuration.
  Do not add a callback layer merely to remove an edge from a dependency graph.

## Complexity and efficiency

- Look for repeated validation at internal boundaries, retained inputs, duplicate
  caches, growing collections, quadratic list append, and repeated compilation.
- Identify when a check is required at a trust boundary before calling it redundant.
- Do not add caches, concurrency, configuration, or a new abstraction to fix a
  small unmeasured cost. Include invalidation and cleanup costs in alternatives.
- Keep compatibility paths until their users and release status are known.
- Try to remove a branch, repeated receive, conversion, or retained value before
  adding a helper. Check event order, deadlines, errors, and memory retention.
  Prefer ordinary control flow over compressed syntax. Long modules and high test
  counts are not sufficient evidence of overengineering.

## Tests, docs, and user cost

- Use guides and examples to establish what a feature enables and how much a
  caller must understand for a simple operation.
- Prefer tests of observable contracts over private helper structure. Check
  failure paths and real runtime wiring, not only mocked successful calls.
- Look for repeated fixtures, sleeps, flaky event ordering, and tests that could
  pass while the production path fails. Propose a specific stronger assertion.
- Distinguish missing coverage from a proven bug. Keep useful integration tests
  even when unit tests already cover the parts.
- For stateful code, test forbidden transitions as well as valid ones: duplicate
  completion, work after cancellation, stale results, and retries after effects.
  Use properties when they express a real invariant. Synchronize concurrent tests
  with messages or monitors; verify cleanup without arbitrary sleeps.
- Explain whether a refinement reduces concepts, duplicated rules, caller work,
  or failure modes. Use net production lines removed as supporting evidence,
  never as a quota or a reason to delete required behavior or useful tests.

## Frameworks and external boundaries — only when present

- For Phoenix/LiveView, trace authorization and long work in the process lifecycle.
  For Ecto, trace query counts, transaction scope, and database constraints. For
  Oban or other job systems, trace retries, duplicate effects, and idempotency.
- Read installed package guidance before proposing replacements for framework
  mechanisms. Do not import web application conventions into a general library.
- At external input boundaries, check unsafe atom creation, term decoding,
  dynamic execution, and sensitive data in logs. Identify a reachable input path;
  an alarming function name alone is not a security finding.
