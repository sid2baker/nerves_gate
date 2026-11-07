# Define the Verification Contract

The plan must say how the implemented software will be proved. Verification is
part of the design because it can change interfaces, unit boundaries, rollout,
and observability.

## Start from acceptance

For each Product Contract requirement and acceptance example, identify the
highest practical boundary that can observe the promised behavior. Prefer a
real caller, public interface, process boundary, or persisted result over an
internal implementation detail.

Use lower-level tests when they give faster or more precise evidence for a
complex rule. Do not replace an end-to-end contract with isolated unit tests.

## Select evidence by risk

The verification contract can include:

- focused behavior tests for each implementation unit;
- integration or contract tests across affected boundaries;
- regression tests for changed or fixed behavior;
- property or invariant tests for stateful and data-heavy rules;
- migration verification queries and compatibility checks;
- static analysis, formatting, compilation, and type checks;
- performance measurements against a named baseline and threshold;
- security and permission scenarios;
- lifecycle, concurrency, timeout, retry, and recovery scenarios;
- packaging, documentation, generated-output, or installation checks; and
- production or staging observation when the acceptance contract requires it.

Use only the methods that can change the verdict. State why a broad gate is
needed when focused evidence cannot cover the risk.

## Use supported commands

Take commands from repository documentation, task configuration, CI, package
manifests, or current scripts. Include the working directory and any safe,
non-secret prerequisites. Do not invent a command from framework convention.

When a command cannot be confirmed, state the intended check and mark the exact
command as an implementation-time confirmation. Do not include credentials,
access-bearing URLs, production identifiers, or destructive flags.

Planning does not need to run the complete future verification suite. It must
verify that the planned command or check exists when that fact is cheap and
material.

## Define unit tests and final gates

Each implementation unit gets its smallest direct proof. The final plan also
gets repository-wide gates that prove integration and prevent regressions.

Use a table:

| Gate | Applies to | Evidence | Done signal |
| --- | --- | --- | --- |
| Focused behavior | U1 | named test or observable scenario | expected outcome passes |
| Integration | U1-U3 | supported command | affected boundaries agree |
| Repository | all units | standard project gate | no relevant regression |

Order gates from fast and focused to broad and costly. Put destructive,
external, or production checks behind their required authority and environment.

## Plan rollback and recovery proof

When the design includes rollout, migration, or external effects, define:

- the pre-deployment evidence;
- compatibility checks during the mixed-version window;
- monitoring signals and alert thresholds;
- abort conditions;
- rollback or forward-recovery actions;
- verification after recovery; and
- cleanup that must wait until the safe window ends.

If rollback is impossible or unsafe after a point, state that point and the
required approval before crossing it.

## Define the Definition of Done

The Definition of Done is the final observable contract. It must include:

- all in-scope Product Contract behavior;
- completed implementation units;
- passed required verification gates;
- preserved compatibility and data invariants;
- completed rollout, migration, and cleanup when in scope;
- updated affected documentation and generated artifacts; and
- no unresolved blocker hidden as an assumption.

Do not include commit, pull request, deployment, or release completion unless
the Product Contract explicitly makes it part of the software outcome.

## Check traceability

Before writing, confirm:

- each requirement maps to a unit and evidence;
- each key technical decision controls at least one unit or risk gate;
- each material risk has prevention, detection, or recovery evidence;
- each exact command is supported by the repository;
- each conditional external check names its authority and environment; and
- the Definition of Done can be judged without reading the planning process.
