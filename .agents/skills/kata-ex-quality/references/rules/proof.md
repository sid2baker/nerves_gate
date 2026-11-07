# Proof rules

Load this file for `focus:proof` or when configured coverage, contract, mutation,
property, or reliability evidence applies.

Proof applies only to its recorded source identity and environment. If the
revision or dirty state differs, report the evidence as stale and rerun it or
mark the surface uninspected. Do not use an old passing report to verify a new
finding or batch.

## Coverage analyzer

The bundled analyzer reads existing Mix, ExCoveralls JSON, umbrella, or HTML
coverage output. It does not generate coverage. Resolve the quality skill
directory, then run from the target project:

```text
elixir <quality-skill-directory>/scripts/coverage.exs --root <project> --threshold <percent> find --commits 30
elixir <quality-skill-directory>/scripts/coverage.exs --root <project> --threshold <percent> suggest
elixir <quality-skill-directory>/scripts/coverage.exs --root <project> analyze <module-or-path>
```

Use the project's threshold and change window when they exist. `mark` writes
`.coverage_progress.txt`; use it only when the operator explicitly asks to mark
completed coverage work. Missing or stale data is a blocker for current proof,
not permission to guess.

## `coverage-gap` version 2

- **Use when:** Fresh coverage data or a configured coverage gate exists.
- **Detect:** Record the exact coverage source, command, source identity, and
  freshness. Resolve each module to its source path. Inspect uncovered blocks,
  current tests, component ownership, and recent changes together.
- **Finding:** One important reachable behavior lacks proof, a changed behavior
  regressed, or a required package or component floor fails. A low percentage by
  itself is only a candidate.
- **Fix:** Add the smallest behavioral test for the missing contract. Do not
  exercise lines without a meaningful assertion.
- **Protect:** Existing tests, package and component floors, line identity,
  contract proof, and test readability.
- **Verify:** Focused tests and the same complete coverage command pass against
  the current source identity.
- **Judgment stop:** The line can be unreachable, generated, defensive, or an
  exclusion candidate, or coverage data is stale.
- **Batch key:** Module and focused coverage command.

## `contract-or-mutation-gap` version 1

- **Use when:** The project has Covenant, mutation testing, property checks, or
  another executable contract system.
- **Detect:** Run the focused proof and inspect the survivor or uncovered
  obligation.
- **Finding:** One required behavioral distinction is not detected.
- **Fix:** Strengthen the nearest test, property, or obligation.
- **Protect:** Coverage, behavior, and contract ownership.
- **Verify:** The gap is gone and focused tests pass.
- **Judgment stop:** Behavior, obligation, or component ownership is disputed.
- **Batch key:** Contract component and proof command.

## `required-suite-instability` version 1

- **Use when:** A required suite failed and later passed without an explained
  source or environment change.
- **Detect:** Preserve the failure, rerun the focused path, and inspect order,
  shared state, cleanup, and process ownership.
- **Finding:** One unexplained reliability failure with a bounded hypothesis.
- **Fix:** Add deterministic coordination, isolation, or cleanup after confirming
  the cause.
- **Protect:** The original assertion and required suite membership.
- **Verify:** Focused repeated runs and the required suite pass. Keep the row open
  until the cause is verified or a project waiver record owns it.
- **Judgment stop:** The only action is retry, quarantine, exclusion, or assertion
  weakening.
- **Batch key:** Suite, failure signature, and lifecycle owner.

## `stale-proof-evidence` version 1

- **Use when:** A report, baseline, or passing result names another revision,
  dirty state, environment, or tool configuration.
- **Detect:** Compare source identity, runtime versions, command, configuration,
  and artifact time with the current run.
- **Finding:** One required conclusion depends on evidence that cannot verify the
  current source.
- **Fix:** Re-run the owning proof or mark the surface uninspected. Do not copy or
  relabel old results.
- **Protect:** Evidence history, source identity, and required suite membership.
- **Verify:** Fresh evidence names the current source and passes its validator.
- **Judgment stop:** The proof cannot run in the available environment.
- **Batch key:** Proof command and source identity.

## `component-ownership-gap` version 1

- **Use when:** Package policy requires each production or public module to have
  one primary proof or architecture owner.
- **Detect:** Compare the current module inventory with explicit records,
  namespace fallbacks, and documented overrides.
- **Finding:** One module is unowned, ambiguously owned, or silently captured by
  a broad fallback.
- **Fix:** Assign the established owner and record a narrow override or fallback.
- **Protect:** Component boundaries, public concepts, and proof attribution.
- **Verify:** Inventory fingerprints and ownership validation pass.
- **Judgment stop:** The correct component or boundary is disputed.
- **Batch key:** Module and competing owners.

## `component-proof-gap` version 1

- **Use when:** A component proof profile requires unit, contract, authoring,
  example, property, fuzz, load, or benchmark evidence.
- **Detect:** Compare every required profile entry with current, complete
  evidence. Validate each not-applicable reason and owner.
- **Finding:** One required proof is missing, incomplete, stale, or excluded
  without an accepted reason.
- **Fix:** Add the smallest missing proof or correct the owned applicability
  record.
- **Protect:** Component contract, required suite, thresholds, and evidence
  completeness.
- **Verify:** Focused proof and the complete profile validator pass.
- **Judgment stop:** Applicability or the component contract is not settled.
- **Batch key:** Component and proof type.

## `changed-line-coverage-regression` version 1

- **Use when:** A configured baseline or change policy protects recently changed
  behavior beyond the package coverage floor.
- **Detect:** Compare the same coverage command and line identity against the
  accepted baseline. Read the uncovered behavior and current tests.
- **Finding:** One changed reachable behavior loses required proof or crosses a
  protected regression limit.
- **Fix:** Add or restore the smallest behavioral test, or remove confirmed dead
  behavior under its own rule.
- **Protect:** Package and component floors, test meaning, and line identity.
- **Verify:** Focused tests and comparable baseline coverage pass.
- **Judgment stop:** The line is generated, unreachable, defensive, or subject to
  a policy decision.
- **Batch key:** Module and changed behavior.

## `property-invariant-gap` version 1

- **Use when:** A parser, codec, state transition, collection, or generated-input
  boundary has a stable invariant across many values.
- **Detect:** State the invariant, generator domain, bounds, shrink behavior, and
  examples that ordinary tests already cover.
- **Finding:** One important invariant has no executable broad-input proof, or a
  configured property does not test it.
- **Fix:** Add a bounded property with useful generators and retained failure
  examples.
- **Protect:** Determinism, runtime budget, valid input distribution, and focused
  examples.
- **Verify:** The property fails on a known bad case and passes with the fix.
- **Judgment stop:** The invariant or generator domain is not established.
- **Batch key:** Invariant and generator family.

## `fuzz-replay-gap` version 1

- **Use when:** Fuzz or randomized proof is required or has found a failure.
- **Detect:** Inspect seed, bounds, reduced input, report completion, and replay
  command.
- **Finding:** One failure cannot be reproduced, or one required run can finish
  without complete replay evidence.
- **Fix:** Persist the seed and smallest safe input, bound generators, and make
  report completion fail closed.
- **Protect:** Runtime budget, sensitive data, generator coverage, and test
  determinism.
- **Verify:** The saved case reproduces the old failure and the corrected run
  produces complete evidence.
- **Judgment stop:** The input cannot be retained or the fuzz policy is undefined.
- **Batch key:** Fuzz suite and failure signature.

## `performance-proof-gap` version 1

- **Use when:** A package claims a speed, memory, throughput, latency, or
  scalability improvement or protects a performance surface.
- **Detect:** Identify workload, limiter, environment, warmup, repetitions,
  distribution, and accepted baseline.
- **Finding:** One performance claim or required surface lacks comparable proof,
  or a protected regression is repeatable.
- **Fix:** Add the smallest stable benchmark or load check, or correct the
  demonstrated regression.
- **Protect:** Functional results, environment identity, noise limits, and test
  runtime.
- **Verify:** Repeated comparable measurements support the conclusion.
- **Judgment stop:** No stable workload, limiter, or acceptance bound exists.
- **Batch key:** Performance surface and workload.

## `public-example-proof-gap` version 1

- **Use when:** Public guides or examples promise a supported authoring or usage
  path.
- **Detect:** Run or compile the exact example under the supported environment
  and trace its public result.
- **Finding:** One supported example is stale, untested, or contradicts the
  public contract.
- **Fix:** Correct the example or implementation according to the established
  contract and add executable proof.
- **Protect:** Public API, documentation intent, and supported versions.
- **Verify:** The example and its focused package tests pass.
- **Judgment stop:** The example's support status is unknown.
- **Batch key:** Public example and API boundary.

## `waiver-governance-gap` version 1

- **Use when:** Required proof can be waived under project policy.
- **Detect:** Check finding ID, owner, reason, expiry, resolution condition,
  affected proof, and current status.
- **Finding:** One waiver is incomplete, expired, broader than its finding, or
  treated as proof.
- **Fix:** Remove an invalid waiver or route renewal and policy changes to the
  owner.
- **Protect:** Open finding visibility, expiry behavior, and audit history.
- **Verify:** The contract rejects invalid waivers and reports the accepted one
  without converting it to a pass.
- **Judgment stop:** A waiver must be created, renewed, or broadened.
- **Batch key:** Waiver and finding ID.
