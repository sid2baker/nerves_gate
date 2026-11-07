# Test rules

Load this file for `focus:tests` or when test-efficiency and test-reliability
detectors apply.

## `test-value-gap` version 1

- **Use when:** A test can be duplicate, stale, assertion-free, coupled to an
  implementation detail, or responsible for test-only production code.
- **Detect:** Read the complete test, its production owner, its non-test
  callers, overlapping tests, and relevant history. State the observable
  behavior or independent contract, one credible regression that the test can
  detect, why stronger existing proof does not already detect it, and every
  production seam that exists only for the test.
- **Finding:** One test has a repeatable maintenance or runtime cost, but no
  distinct supported behavior, invariant, boundary, or regression that needs
  its current proof.
- **Fix:** Prefer extending a stronger owning-boundary test, rewriting the test
  at that boundary, or removing an approved duplicate. Remove test-only
  production code only after reachability and package checks prove that no
  production caller needs it.
- **Protect:** Public behavior, defect regression, package entry points,
  protocols, configuration, storage, security, generated output, coverage,
  required gates, and all behavior named by the finding.
- **Verify:** Show the original behavior protection, the replacement or
  remaining proof, focused and sibling test results, required gates, and a
  build or dead-code result for removed production code. Coverage percentage,
  grep output, test count, age, or runtime alone is not proof of equal value.
- **Judgment stop:** The protected contract, production reachability, history,
  stronger proof, or required validation is unknown. Record the candidate but
  do not select it for application.
- **Batch key:** Production owner, protected contract, and validation boundary.

This rule is always `judgment-required` and is never automatically applied.
Test deletion needs explicit authority for the named batch. A scan can report
zero ready candidates. Do not add weak candidates to meet a count.

When the project already has a test registry, or the user requests one, record
test assets by module, suite, or critical workflow. Link requirements, defects,
risks, and boundary contracts to executable evidence without copying every test
function or the source success criteria. Do not create a registry only because
this rule ran.

## Test-efficiency scan

Inspect these cues before a runtime claim:

- fixed sleeps and repeated polling that only coordinate processes;
- broad `async: false` use and shared global resources;
- repeated application, supervisor, database, or external-service startup;
- behaviorful fixtures or cleanup helpers repeated across consumers;
- setup work that a test does not use; and
- slow modules or tests from comparable repeated measurements.

Route each confirmed root cause to the most specific rule below. A source cue is
not a finding until its behavior, owner, and protection are known. Do not extract
expected values into a fixture or remove a test only to improve runtime.

## `test-arbitrary-sleep` version 2

- **Use when:** Test code sleeps for another process or effect.
- **Detect:** Trace whether elapsed time is behavior or only coordination.
- **Finding:** One arbitrary delay controls readiness or order.
- **Fix:** Use a message, monitor, barrier, supervised lifecycle, or bounded
  condition check.
- **Protect:** Assertion meaning, timeout behavior, process cleanup, and
  comparable coverage.
- **Verify:** Focused repeated runs and the original protection pass. Compare
  timing only when the same command and environment ran more than once.
- **Judgment stop:** Real elapsed time is the contract under test, or process
  lifecycle ownership is unclear.
- **Batch key:** Coordination protocol and test module.

## `test-unnecessary-serialization` version 2

- **Use when:** A test module disables asynchronous execution.
- **Detect:** Trace environment, registered names, files, databases, application
  startup, mocks, telemetry, and other shared state before repeated randomized
  runs. Measure a comparable baseline before a speed claim.
- **Finding:** One module is serial without a shared-resource requirement.
- **Fix:** Isolate the resource or enable asynchronous execution.
- **Protect:** Reliability, cleanup, assertions, and comparable configured
  coverage.
- **Verify:** Repeated randomized focused and neighboring runs pass. Use repeated
  comparable suite timing when speed is claimed.
- **Judgment stop:** Resource ownership or isolation policy is unclear.
- **Batch key:** Shared resource and test group.

## `test-fixture-duplication` version 2

- **Use when:** Tests repeat behaviorful fake modules, setup, or data builders.
- **Detect:** Confirm exact or near duplication, identify synchronized edits or
  unused setup work, and read every consumer.
- **Finding:** One repeated fixture concept causes synchronized edits or unused
  setup work.
- **Fix:** Extract the smallest named support fixture or conditional case helper.
- **Protect:** Visible expected values, isolated state, consumer-specific setup,
  and comparable coverage.
- **Verify:** All consumers and protected coverage pass; duplicate structure is
  absent. Measure repeated comparable runtime only when speed is claimed.
- **Judgment stop:** Extraction creates a mystery fixture, broad setup, or hidden
  expected result.
- **Batch key:** Fixture concept and consumers.

## `test-runtime-hotspot` version 2

- **Use when:** The test command reports slow tests or modules.
- **Detect:** Measure the same command and environment more than once. Include
  setup and distinguish serial trace time from parallel suite time. Inspect
  repeated startup, unused setup, compilation, polling, and external waits.
- **Finding:** One repeatable hotspot does avoidable work that is not the tested
  behavior.
- **Fix:** Reduce unused setup, repeated compilation, waits, or broad resource
  startup without removing proof.
- **Protect:** Assertions, coverage, contract proof, and cleanup.
- **Verify:** Focused behavior passes and repeated measurements improve.
- **Judgment stop:** The change removes proof or relies on one noisy sample.
- **Batch key:** Test module, setup owner, and timing command.

## `test-order-dependence` version 1

- **Use when:** Results change with seed, isolation, or prior test state.
- **Detect:** Reproduce the failing seed, then find the smallest sequence that
  identifies leaked state.
- **Finding:** One shared-state or cleanup cause makes order affect results.
- **Fix:** Give state one owner, use unique resources, and restore or supervise
  lifecycle state.
- **Protect:** The failing assertion and randomized execution.
- **Verify:** The original seed, repeated new seeds, and focused suite pass.
- **Judgment stop:** A deliberate global integration boundary has no owner.
- **Batch key:** Shared-state owner and affected tests.

## `test-process-leak` version 1

- **Use when:** A test starts a process, task, supervisor, timer, monitor, or
  registered resource that can outlive the test.
- **Detect:** Trace ownership and cleanup on success, assertion failure, timeout,
  and test-process exit.
- **Finding:** One test resource can leak or affect later tests.
- **Fix:** Use the test supervisor, `on_exit`, monitoring, or an owned cleanup
  protocol.
- **Protect:** Production lifecycle behavior, failure visibility, and test
  isolation.
- **Verify:** Focused repeated and neighboring randomized tests pass with no live
  resource after exit.
- **Judgment stop:** The test intentionally verifies detached lifetime.
- **Batch key:** Test resource and lifecycle owner.

## `test-shared-state-leak` version 1

- **Use when:** Tests mutate application environment, persistent terms, ETS,
  files, registries, telemetry, mocks, or global names.
- **Detect:** Run the test alone and with randomized neighbors while tracing
  setup, restore, and owner exit.
- **Finding:** One mutation survives its test or depends on prior state.
- **Fix:** Give state a unique per-test resource or restore it under owned
  cleanup.
- **Protect:** Parallel execution, production defaults, and failure paths.
- **Verify:** Original and several randomized seeds pass in isolation and in the
  neighboring suite.
- **Judgment stop:** A deliberate global integration boundary has no isolation
  policy.
- **Batch key:** Global resource and test group.

## `test-external-nondeterminism` version 1

- **Use when:** An offline test depends on wall time, random values, network,
  provider state, system load, or unordered external output.
- **Detect:** Identify the uncontrolled input and reproduce its effect under a
  fixed substitute or bound.
- **Finding:** One required offline result can vary without a source change.
- **Fix:** Inject or own time, randomness, provider fixtures, ordering, or
  capacity while retaining separate live checks when required.
- **Protect:** Real boundary semantics and explicit integration coverage.
- **Verify:** Repeated offline runs are stable and selected live checks remain
  separate.
- **Judgment stop:** The suite is explicitly a live or load surface.
- **Batch key:** External input and suite.

## `test-broad-setup` version 1

- **Use when:** Setup creates data, processes, applications, mocks, or services
  that many tests do not use.
- **Detect:** Trace each setup value and side effect to its consumers and measure
  cost when runtime is claimed.
- **Finding:** One shared setup performs unused work or widens state coupling.
- **Fix:** Move work to the smallest named setup or fixture used by its consumers.
- **Protect:** Readability, cleanup, visible expected values, and coverage.
- **Verify:** All consumers pass and unused setup is absent; measure again for a
  speed claim.
- **Judgment stop:** The setup establishes an intentional integration boundary.
- **Batch key:** Setup owner and consumer set.

## `test-hidden-expected-value` version 1

- **Use when:** A fixture, helper, macro, or shared assertion hides the value or
  behavior that a test is meant to prove.
- **Detect:** Read the test without helper implementation and identify whether
  the contract and expected result remain clear.
- **Finding:** One abstraction makes a failing behavioral distinction hard to
  see or change independently.
- **Fix:** Keep construction reusable but move the important expected value or
  assertion to the test.
- **Protect:** Duplication reduction, domain vocabulary, and focused failure
  output.
- **Verify:** Tests still cover the same behavior and failures name the contract.
- **Judgment stop:** The helper is itself the named reusable contract.
- **Batch key:** Fixture or assertion helper and behavior.

## `test-implementation-coupling` version 1

- **Use when:** A test asserts private functions, exact internal messages,
  incidental call counts, or structure not promised by the public contract.
- **Detect:** Compare the assertion with public behavior, fault boundaries, and
  supported observability.
- **Finding:** One test blocks valid implementation change without protecting a
  required result.
- **Fix:** Assert the nearest observable contract while retaining important
  ordering or effect checks.
- **Protect:** Defect detection, failure paths, and performance limits.
- **Verify:** The test fails on a representative contract violation and passes
  after an internal-only change.
- **Judgment stop:** The internal protocol is itself supported or safety-critical.
- **Batch key:** Test and protected contract.

## `test-boundary-proof-gap` version 1

- **Use when:** Unit tests cover pure parts but no test exercises the real public
  boundary, runtime wiring, or adapter composition.
- **Detect:** Trace one public success and failure path through actual boundary
  code and identify what current tests replace or skip.
- **Finding:** One supported integration can be broken while all existing tests
  pass.
- **Fix:** Add the smallest boundary test that calls the API as a user and owns
  external substitutes.
- **Protect:** Unit-test speed, error behavior, lifecycle, and cleanup.
- **Verify:** The boundary test fails on a representative wiring defect and
  passes on the current contract.
- **Judgment stop:** The boundary requires live infrastructure with no accepted
  offline substitute.
- **Batch key:** Public boundary and integration path.

## `test-randomness-replay-gap` version 1

- **Use when:** Random order, generated values, or fuzz inputs affect a required
  test.
- **Detect:** Check that seed, reduced input, and exact replay command are
  reported and retained safely.
- **Finding:** One failure cannot be repeated from its test output or artifact.
- **Fix:** Make the seed and reduced input explicit and keep generation bounded.
- **Protect:** Input diversity, runtime budget, and sensitive values.
- **Verify:** The recorded failure replays and normal seeded runs remain varied.
- **Judgment stop:** Inputs cannot be retained under project policy.
- **Batch key:** Randomized suite and replay artifact.

## `test-assertion-gap` version 1

- **Use when:** A test executes code but has no observable assertion, expected
  failure, contract artifact, or meaningful pattern match.
- **Detect:** Trace what behavior would make the test fail and whether setup or
  helper failures only prove execution.
- **Finding:** One test passes without distinguishing the required behavior from
  a representative defect.
- **Fix:** Add the smallest observable assertion or remove the test only when it
  protects no distinct behavior and coverage remains protected.
- **Protect:** Coverage, compile examples, side-effect checks, and failure output.
- **Verify:** A representative bad result fails the test.
- **Judgment stop:** Successful compilation or absence of a crash is the stated
  contract.
- **Batch key:** Test and missing distinction.
