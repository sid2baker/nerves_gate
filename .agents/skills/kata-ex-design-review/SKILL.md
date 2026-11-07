---
name: kata-ex-design-review
description: "Review an Elixir package or subsystem as a principal engineer. Find unnecessary complexity, unclear contracts, and missed Elixir or OTP patterns. Use for deep design reviews and simplification proposals, including existing code without a diff. Report by default; apply local fixes only when requested."
metadata:
  schema: kata.skill/v1
  subject: software-engineering
  practice: review
  object: software-design
  profile: system-design
  authority: local-write
  consumes: "elixir-codebase, design-review-request"
  produces: "design-assessment, verified-change"
  language: elixir
---

# Elixir Design Review

**Outcome:** A decision-ready Elixir design assessment for the package
maintainer, or verified local fixes when the operator requests them.

**Done:** Every in-scope responsibility has a traced contract and evidence or a
concrete blocker. Findings, preserved decisions, checks, limits, and any applied
changes are reported against one recorded source state.

## Assignment

The required input is one package, subsystem, or bounded set of paths. A
comparison ref, focus, or `apply:local` mode is optional. The practice is Elixir
and OTP design review. The work profile is `system-design` for a package-wide
contract review and `bounded-execution` for one narrow boundary.

Direct user authority or inherited caller authority permits local inspection
and proportionate review checks. Default authority is report-only. Apply source
changes only with `apply:local` or an explicit fix request, and keep them inside
the selected scope. API breaks, feature removal, dependency installation,
branch changes, commits, pushes, pull requests, publication, and live-system
changes require separate authority. The primary reviewer owns coverage,
cross-boundary synthesis, verification, and the final assessment. Ask the
operator when scope, source revision, or change authority remains ambiguous.
Report-only work produces `design-assessment`; an applied and verified local
fix also produces `verified-change`.

Arguments: `<package or paths> [ref or comparison] [focus] [apply:local]`.

Find the smallest clear implementation that meets the required contracts.
Strongly favor deleting unnecessary code, branches, state, and layers. New code
must earn its cost. Preserve useful features and justified fault boundaries;
do not trade clear code or required behavior for a lower line count.
This skill works on a package, subsystem, or named change; it needs no other
skills, hooks, or services. It can use native subagents and also works alone.

## 1. Establish the contract

- Resolve the named repository, paths, and ref. If scope is absent, use one package
  clearly established by the conversation; otherwise ask. Do not expand to sibling
  packages. Stop if the scope contains no Elixir implementation to review.
- Check `git status --short --branch` in each selected repository. Record the
  reviewed commit, comparison base if any, and included local/untracked files.
  For another ref, inspect that ref consistently; do not mix in workspace files
  or switch branches. Outside Git, state that no commit can be recorded.
- Read applicable project instructions, supported Elixir/OTP versions, relevant
  package usage rules, API docs, guides, examples, and tests. Identify feature
  purpose, consumers, guarantees, and deliberate tradeoffs before judging design.
- A package request covers the full package design. A repeated request keeps that
  scope unless the user asks for a focused pass. Verify old fixes, then perform a
  fresh review; do not substitute the prior report or its unreviewed areas.
  In later rounds, challenge earlier fixes as current code: try inputs and event
  orders their tests missed, inspect sibling paths, and check new complexity.
  A passing regression test does not settle the design.
- Existing reviews are leads, not evidence. Read outside scope only to establish
  callers or contracts; keep those observations separate from in-scope findings.

## 2. Trace the design

Build a short coverage table before judging the design. Use one row per actual
responsibility, such as public contracts, validation, authoring, storage,
compilation, execution, process ownership, and observability. Record entry points,
implementation/test paths, the contract traced, and status: pending, traced, or
blocked. Adapt the rows to the package; this is not a file-count checklist.

For each row, trace a success path and a reachable failure path from a public
entry point to its result. Identify data types, state owners, effects, and cleanup.
For concurrency, compare completion before and during a wait, cancellation,
owner/worker death, and stale state where applicable. For extension contracts,
check a minimal valid custom implementation as well as generated defaults.
Use bounded reads; truncated output and search matches do not count as inspected
implementation. Keep the coverage table current as the work proceeds.

Read [review lenses](references/review-lenses.md). Apply relevant lenses to the
implementation and its callers. A long function, large module, one implementation
of a behaviour, or many tests is a clue, not proof of poor design.

Read [the package lens index](references/package-index.md). Inspect the target's
locked dependencies and scope, then read each matching file under
`references/packages/`. Apply several package lenses when an integration crosses
their boundaries. Package lenses refine the review questions; installed source
and official versioned documentation remain the authority.

For each candidate, establish the requirement served, the concrete cost or
failure, and the guarantees it must preserve. Compare alternatives in this order:
remove redundant work or structure; simplify in place with ordinary Elixir/OTP;
reuse an existing owner; introduce a new abstraction only if those are inadequate.
Prefer the smallest correct option. A new module, wrapper, option, or shared
helper needs a concrete contract or maintenance benefit that the smaller option
cannot provide. Repeated syntax or possible future reuse is not enough.
Search for evidence that justifies the current design before retaining a finding.
For a full package review with separable responsibilities, use native subagents
when available. Keep a narrow review inline unless an independent check has a
clear benefit. Read [reviewer coordination](references/reviewer-coordination.md)
before dispatch. The primary reviewer owns the coverage table, cross-boundary
traces, verification, and final assessment; delegation does not reduce scope.

## 3. Verify findings

Use the smallest check that resolves the uncertainty:

- Re-read the exact location and callers. A defect needs a reachable trigger and
  expected versus actual behavior. Tests support the contract but can be wrong.
  For types, stored terms, sanitizers, and lifecycle events, use the boundary
  checks in [review lenses](references/review-lenses.md).
  State a testable hypothesis, run the smallest probe, and record its outcome.
  Use temporary probes in review mode; do not add tests to the package.
- For each confirmed defect or previous fix, search sibling paths for the same
  assumption. Compare direct/nested calls and generated/custom implementations
  where those contracts apply. Merge instances with one root cause, but identify
  every verified affected boundary. Inspect test setup for consumed messages or
  other state changes that exclude the failure being investigated.
- Use existing compiler, formatter, lint, and analysis results for the reviewed
  revision, or run relevant configured checks. Report tool failures once; do not
  repeat each as a design finding. Passing tools do not prove sound design.
- For suspected coupling, inspect dependency edges with the project's supported
  `mix xref` options. Distinguish compile, export, and runtime dependencies. A
  cycle needs a concrete cost or ownership problem before it warrants a redesign.
- Verify uncertain language or library claims against official documentation for
  the project's versions. Community skills provide hypotheses, not authority.
- For performance, identify a relevant workload and metric. Profile or benchmark
  when needed. Compare equivalent inputs and results under the same environment.
  Without measurement, report a suspected cost as an investigation, not a speedup.
  Inspect Core Erlang or BEAM code only for a specific unresolved compiler question.

Review mode permits checks and temporary build output, but no source/config edits,
new dependencies, automatic fixes, or live-system changes. Inspect project aliases
before running them. If checks cannot run, continue with explicit limits. Do not
install tooling or rewrite usage rules just to complete a review.

Classify findings separately from their priority:

| Class | Evidence required |
| --- | --- |
| Defect | Reachable violation of a required contract. |
| Safe refinement | Concrete clarity or maintenance benefit with unchanged behavior. |
| Design decision | Benefit and cost of changing an API, ownership, feature, or guarantee. |
| Investigation | A specific unresolved question and a way to answer it. |

Merge findings with the same root cause. Rank by impact, frequency, confidence,
and change risk. Only a demonstrated failure of a required contract warrants a
release blocker. Omit taste-only changes and speculative findings presented as facts.
Do not force a minimum count or remove a feature simply to make the code smaller.
For mature code, a clean review is a useful result. A refinement must reduce a
specific maintenance cost enough to justify its change and verification cost.
Do not turn a minor edge-case defect into a broad design indictment.

## 4. Complete the review, then report or apply

Before a package-wide verdict, close every coverage row with a traced contract
and evidence, or a concrete blocker. Continue pending work; passing tests or a
lack of findings is not a completion rule. A blocked area makes the review
partial. Name it and limit the conclusion accordingly. Full design coverage
means all responsibilities were traced, not proof that every branch is correct.
Recheck the revision and working tree before reporting. Reuse prior check results
only for the same source state, and distinguish them from checks run this time.

For multi-round work, keep a durable decision ledger outside package source.
Use the requested review output directory or a task-specific output location;
report its path. Keep one entry per root cause or design choice: stable ID,
contract, source state/round, evidence or probe, decision (fix, preserve, reject,
defer), reason, verification, and condition for reopening it. Link later evidence
to the same entry. Record sound decisions and rejected simplifications as well
as defects. A deferred choice is not a verified fix. Save enough evidence to
resume after context loss; exclude secrets and unnecessary raw output.

Convergence requires a full pass on the final source state with all coverage
rows closed, no new actionable findings, and earlier fixes and decisions checked
against their contracts. Required checks must pass or have explicit limits.
Do not force findings or repeat settled choices without new evidence. If a pass
changes code, passing tests alone do not establish convergence. Respect a fixed
round count or review budget: stop at that limit and report remaining findings,
blocked areas, or that the final changed state has not had a full review. Do not
add rounds without authorization. A blocked area permits only a partial verdict.

Lead with the assessment, then give:

- Scope, reviewed revision, compact coverage table, limits, and sound decisions
  to preserve. Include material rejected hypotheses and why they were rejected;
  do not list every search or routine check.
- Package-specific assessments for each selected lens. Report only the sections
  that materially affect the reviewed scope.
- Findings ordered by priority. Use `F1`, `F2`, etc. For each: class, priority,
  confidence, `file:line`, evidence and impact, concrete alternative, compatibility
  risk, and a focused verification method. Name what can be removed. If the
  proposal adds structure, explain why the smaller alternative is insufficient.
  Small code sketches are optional.
- Separate investigations and design choices from verified defects/refinements.
- Checks run with results, then a short change order when dependencies matter.

When a run reveals a reusable review lesson, state the evidence, the general
rule, and its limits. Record sound decisions and rejected simplifications too.
Keep project-specific evidence outside the published skill. Propose a small
update to an existing rule or evaluation case; change skill or project guidance
only when requested. An unfixed finding is not a proven solution.

Say when there are no actionable findings. Write a report file only when asked.
Do not commit, push, open PRs, or publish the report unless requested.

With `apply:local` or an explicit request to fix findings, apply verified defects
and safe refinements inside the authorized scope. General cleanup does not grant
permission for API breaks or feature removal; honor specific authorization already
given. Preserve unrelated edits and keep changes independently reviewable.
Fix the demonstrated contract failure first. Do not bundle generic hardening,
new callback policies, or speculative extension points into a small fix. Trace
existing error and cleanup handling before adding another layer.

For safe refinements, preserve results, errors, effects, ordering, cancellation,
cleanup, and observability. Before deleting code, check dynamic dispatch, macros,
behaviours, protocols, configuration, supervision, and external consumers. No
internal callers does not prove that a public API is unused.

Before verification, review the patch for removal: can a new helper, wrapper,
branch, or copied value disappear while the fix remains? Check callers before
moving code; relocation alone is not simplification. Keep regression tests and
required failure handling. Do not compress syntax or weaken tests to reduce lines.

After edits, run the package's format check, compile with warnings as errors,
configured analysis, and tests matched to the affected behavior. Broaden tests for
shared runtime or contract changes. Fix change-caused failures or undo only those
edits; never weaken checks. Report applied, skipped, and unresolved findings, plus
verification limits. Report the production line and module change against the
pre-edit state, including untracked files; count tests and docs separately. Explain
any net production growth in terms of the required contract, not passing checks.
For performance changes, include the comparison evidence.
