# Quality rule index

Read this index for every discovery run. Load only the playbooks selected by the
focus and available configured tools. A rule is an evidence method, not a
mandatory dependency.

## Rule contract

Every built-in and project rule defines an ID, version, surface, cost,
confirmation profile, application profile, default detector effects, default
class, automatic-fix eligibility, playbook, applicability, detector, root-cause
unit, normal fix, protections, verification, judgment stop, and batch key. Read
[the execution profiles](execution-profiles.md) before application.

A material behavior change increments `rule_version`. Old evidence keeps its
recorded version. A project rule uses a project prefix. It can add package policy
or set advisory built-in applicability through `docs/quality/rules.csv`. It
cannot disable a configured gate or weaken a protection.

## Built-in index

### Gates — [playbook](rules/gates.md)

| Rule | Ver. | Cost | Confirm | Apply | Effects | Default class | Auto |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| `gate-failure-router` | 1 | cheap | low | n/a | read-only | route-only | no |
| `format-drift` | 1 | cheap | low | low | read-only | objective-fix | yes |
| `compile-warning` | 1 | normal | medium | medium | build-write | objective-fix | yes |
| `credo-finding` | 2 | cheap | low | medium | read-only | objective-fix | yes |
| `dialyzer-warning` | 1 | expensive | high | high | build-write, cache-write | objective-fix | yes |
| `documentation-gap` | 1 | normal | medium | medium | tool-specific | objective-fix | yes |
| `quality-contract-drift` | 1 | normal | medium | high | tool-specific | judgment-required | no |
| `stale-waiver-or-ignore` | 1 | cheap | medium | medium | read-only | objective-fix | yes |
| `unused-dependency` | 1 | normal | high | high | build-write | judgment-required | conditional |
| `package-artifact-drift` | 1 | normal | medium | medium | build-write, report-write | objective-fix | yes |

### Proof — [playbook](rules/proof.md)

| Rule | Ver. | Cost | Confirm | Apply | Effects | Default class | Auto |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| `coverage-gap` | 2 | expensive | medium | medium | build-write, report-write | objective-fix | yes |
| `contract-or-mutation-gap` | 1 | expensive | high | high | build-write, report-write | objective-fix | yes |
| `required-suite-instability` | 1 | expensive | high | high | build-write | objective-fix | yes |
| `stale-proof-evidence` | 1 | cheap | low | n/a | read-only | backpressure-gap | no |
| `component-ownership-gap` | 1 | normal | high | high | tool-specific | judgment-required | no |
| `component-proof-gap` | 1 | normal | medium | medium | tool-specific | objective-fix | yes |
| `changed-line-coverage-regression` | 1 | expensive | medium | medium | build-write, report-write | objective-fix | yes |
| `property-invariant-gap` | 1 | expensive | high | high | build-write, report-write | judgment-required | conditional |
| `fuzz-replay-gap` | 1 | normal | medium | medium | build-write, report-write | objective-fix | yes |
| `performance-proof-gap` | 1 | expensive | high | high | build-write, report-write | judgment-required | no |
| `public-example-proof-gap` | 1 | normal | medium | medium | build-write | objective-fix | yes |
| `waiver-governance-gap` | 1 | normal | medium | n/a | read-only | judgment-required | no |

### Tests — [playbook](rules/tests.md)

| Rule | Ver. | Cost | Confirm | Apply | Effects | Default class | Auto |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| `test-value-gap` | 1 | expensive | high | high | build-write, report-write | judgment-required | no |
| `test-arbitrary-sleep` | 2 | normal | medium | high | read-only | safe-refinement | yes |
| `test-unnecessary-serialization` | 2 | expensive | high | high | build-write | safe-refinement | yes |
| `test-fixture-duplication` | 2 | normal | medium | medium | read-only | safe-refinement | yes |
| `test-runtime-hotspot` | 2 | expensive | medium | medium | build-write, report-write | safe-refinement | yes |
| `test-order-dependence` | 1 | expensive | high | high | build-write | objective-fix | yes |
| `test-process-leak` | 1 | expensive | high | high | build-write | objective-fix | yes |
| `test-shared-state-leak` | 1 | expensive | high | high | build-write | objective-fix | yes |
| `test-external-nondeterminism` | 1 | expensive | high | high | build-write | safe-refinement | yes |
| `test-broad-setup` | 1 | normal | medium | medium | read-only | safe-refinement | yes |
| `test-hidden-expected-value` | 1 | normal | medium | medium | read-only | safe-refinement | yes |
| `test-implementation-coupling` | 1 | normal | high | high | read-only | judgment-required | conditional |
| `test-boundary-proof-gap` | 1 | expensive | high | high | build-write, report-write | objective-fix | yes |
| `test-randomness-replay-gap` | 1 | normal | medium | medium | build-write, report-write | objective-fix | yes |
| `test-assertion-gap` | 1 | normal | medium | medium | read-only | judgment-required | conditional |

### Code — [playbook](rules/code.md)

| Rule | Ver. | Cost | Confirm | Apply | Effects | Default class | Auto |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| `duplicate-code` | 2 | normal | high | high | tool-specific | judgment-required | conditional |
| `confirmed-dead-code` | 2 | expensive | high | high | build-write, report-write | objective-fix | yes |

### Data foundations — [playbook](rules/data.md)

| Rule | Ver. | Cost | Confirm | Apply | Effects | Default class | Auto |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| `data-access-shape-mismatch` | 1 | expensive | high | high | tool-specific | judgment-required | no |
| `data-invariant-gap` | 1 | normal | high | high | read-only | judgment-required | conditional |
| `normalization-owner-gap` | 1 | normal | high | high | read-only | judgment-required | conditional |
| `boundary-key-shape-drift` | 1 | normal | high | high | read-only | objective-fix | yes |
| `data-roundtrip-loss` | 1 | normal | high | high | build-write | objective-fix | yes |
| `error-contract-drift` | 1 | normal | high | high | read-only | judgment-required | conditional |
| `internal-wire-data-conflation` | 1 | normal | high | high | read-only | judgment-required | no |
| `invalid-state-encoding` | 1 | normal | high | high | read-only | judgment-required | no |
| `option-flag-complexity` | 1 | normal | high | high | read-only | judgment-required | no |
| `wrapper-without-contract` | 1 | normal | high | high | read-only | judgment-required | no |
| `unsafe-compile-time-data` | 1 | expensive | high | high | build-write | judgment-required | conditional |
| `observable-secret-leak` | 1 | expensive | high | high | build-write, report-write | objective-fix | yes |
| `broad-exception-recovery` | 1 | normal | high | high | read-only | judgment-required | conditional |

### Architecture policy — [playbook](rules/architecture.md)

| Rule | Ver. | Cost | Confirm | Apply | Effects | Default class | Auto |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| `architecture-policy-violation` | 1 | expensive | high | high | tool-specific | objective-fix | yes |
| `backpressure-capability-gap` | 1 | expensive | high | n/a | read-only | backpressure-gap | no |

### OTP layering — [playbook](rules/otp.md)

| Rule | Ver. | Cost | Confirm | Apply | Effects | Default class | Auto |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| `data-before-process-gap` | 1 | expensive | high | high | read-only | judgment-required | no |
| `functional-core-gap` | 1 | expensive | high | high | read-only | judgment-required | no |
| `process-without-runtime-need` | 1 | expensive | high | high | read-only | judgment-required | no |
| `process-machinery-leak` | 1 | normal | high | high | read-only | judgment-required | conditional |
| `boundary-api-gap` | 1 | normal | high | high | read-only | judgment-required | conditional |
| `call-cast-backpressure-gap` | 1 | expensive | high | high | tool-specific | judgment-required | no |
| `lifecycle-owner-gap` | 1 | expensive | high | high | tool-specific | judgment-required | conditional |
| `state-transition-multi-owner` | 1 | expensive | high | high | tool-specific | judgment-required | conditional |
| `unsupervised-process` | 1 | expensive | high | high | build-write | judgment-required | conditional |
| `task-owner-gap` | 1 | expensive | high | high | build-write | judgment-required | conditional |
| `timer-monitor-cleanup-gap` | 1 | expensive | high | high | build-write | judgment-required | conditional |
| `blocking-server-callback` | 1 | expensive | high | high | build-write, report-write | judgment-required | no |
| `mailbox-pressure-gap` | 1 | expensive | high | high | build-write, report-write | judgment-required | no |
| `oversized-process-message` | 1 | expensive | high | high | report-write | judgment-required | no |
| `derivable-process-state` | 1 | normal | high | high | read-only | judgment-required | no |
| `persistence-core-coupling` | 1 | expensive | high | high | read-only | judgment-required | no |
| `external-effect-idempotency-gap` | 1 | expensive | high | high | tool-specific | judgment-required | no |
| `fault-domain-mismatch` | 1 | expensive | high | high | tool-specific | judgment-required | no |
| `retry-policy-gap` | 1 | expensive | high | high | tool-specific | judgment-required | conditional |
| `shutdown-cleanup-gap` | 1 | expensive | high | high | build-write | judgment-required | conditional |
| `supervision-policy-mismatch` | 1 | expensive | high | high | build-write | judgment-required | conditional |
| `layer-dependency-inversion` | 1 | expensive | high | high | tool-specific | judgment-required | no |

Default effects are intake guidance, not permission to run a command. A project
alias or tool version can add effects. Inspect the exact configured command.
`tool-specific` means that no safe default is available before inspection.
`conditional` means that the default finding is not eligible for application.
It becomes eligible only after direct evidence supports reclassification as an
objective fix or safe refinement under the skill's complete safety test.

`gate-failure-router` never creates a backlog row. It maps configured command
failures to the most specific rule. If no built-in owns the cause, create a
project-prefixed rule before recording the finding.

## Loading

- `focus:gates` loads `rules/gates.md`.
- `focus:proof` loads `rules/proof.md`.
- `focus:tests` loads `rules/tests.md`.
- `focus:code` loads `rules/code.md` and `rules/data.md`.
- `focus:data` loads `rules/data.md`.
- `focus:architecture` loads `rules/architecture.md` and `rules/otp.md`.
- `focus:otp` loads `rules/otp.md`.
- `rule:ID` loads only the playbook that owns the selected rule.
- `focus:all` loads playbooks only as their configured capability or cheap
  source detector becomes applicable.

At standard depth, load `rules/data.md` when code shows a codec, repeated
normalization, inconsistent key or error forms, compile-time caller data,
sanitization, or a wrapper with unclear ownership. Load `rules/otp.md` when the
scope uses processes, supervisors, tasks, timers, monitors, runtime persistence,
or external effects. At thorough depth, trace every applicable layer but stop at
the work ceiling. Do not read all playbooks only because they exist.

Within one surface, inspect cheap rules before normal and expensive rules unless
a required gate or open backlog row sets a higher priority.
