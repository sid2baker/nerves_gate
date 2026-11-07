---
name: kata-plan
description: "Create a deeply grounded software implementation plan from a clear request, Product Contract, or existing plan. Use when software work has technical decisions, cross-file effects, dependencies, migrations, or several verifiable units; do not use to explore product direction, diagnose an unknown failure, or implement the change."
metadata:
  kata-argument-hint: "[software request, Product Contract path, or plan path] [output:html] [beadwork] [chat-only]"
  schema: kata.skill/v1
  subject: software-engineering
  practice: plan
  object: software-effort
  profile: system-design
  authority: local-write
  consumes: "planning-request, product-contract, decision-roadmap, understood-context, existing-plan"
  produces: "implementation-plan, verified-change"
---

# Plan Software Work

**Outcome:** A software implementer receives a grounded plan that preserves the
requested behavior and resolves the technical sequence, dependencies, tests,
and delivery risks needed to start work without inventing important decisions.

**Done:** The canonical Markdown plan exists, or the user explicitly requested
chat-only output; its readiness is accurate; its product, technical, unit, and
verification contracts agree; and each requested optional adapter has a
verified result or an explicit limit.

## Assignment and authority

The required input is one software planning request, Product Contract,
completed decision roadmap, understood context, or existing plan. Product
behavior, scope, and acceptance must be clear enough to plan. The skill can
resolve technical design and sequencing decisions. It must not silently decide
a product, security, data, public-interface, or operating-policy question that
changes the requested outcome.

Direct user authority or inherited caller authority permits read-only
repository research and local plan artifacts. An explicit `beadwork` request
also permits local issue-graph writes in an already initialized Beadwork
repository. Preserve unrelated and concurrent work.

Do not edit product code, run migrations, install dependencies, initialize or
repair Beadwork, create a branch or commit, change remote state, publish an
artifact, invoke another skill as a required step, select another model, or
start implementation. Ask the accountable owner when a missing decision can
materially change behavior, scope, cost, risk, stored data, a public contract,
or an irreversible effect.

## Activation boundary

An explicit invocation always produces or updates a software plan. It does not
reject a small request only because implementation could be quick. It can make
the plan compact, but it must keep the required evidence and execution
contracts.

Use another workflow before planning when the request still needs product
exploration, needs a durable multi-session decision roadmap, or has an unknown
failure cause. Start implementation without this skill when the target, action,
acceptance conditions, and authority are already complete and no material
sequence or dependency decision remains. This package does not plan
non-software work in its first version.

## Inputs and preservation

Read [references/software/intake.md](references/software/intake.md) first. It
owns target resolution, input classification, product-readiness checks,
existing-plan behavior, output tokens, and blocking questions.

Accept these inputs as alternatives:

- a requirements-only Product Contract;
- a completed decision roadmap with a planning handoff;
- supported understood context plus a clear requested outcome;
- a direct request that already supplies behavior, scope, and acceptance; or
- an existing implementation plan that needs a named revision or deeper pass.

When a Markdown Product Contract has `artifact_readiness:
requirements-only`, enrich that same file. Preserve its product decisions and
stable requirement IDs. Normalize a legacy `ce-unified-plan/v1` contract to
`kata-plan/v1` only as part of that enrichment. When no upstream artifact
exists, capture only settled product facts from the request and evidence. Do
not make a hidden Product Contract to fill a gap.

## Canonical output and adapters

Markdown is the canonical plan format. A repository-backed invocation writes
Markdown under the repository's established plan directory, normally
`docs/plans/`, unless the user requests chat-only output. A request with no
repository returns Markdown in chat unless it supplies a save location.

Adapters are optional and do not change the planning method:

- `output:html` creates a derived HTML view beside the canonical Markdown.
- `beadwork` materializes implementation units and blocking edges in an
  existing Beadwork repository.
- CSV is not supported in this version.

Use this order: write and check Markdown, materialize Beadwork when requested,
update Markdown with actual issue IDs, then render HTML when requested. Never
edit the derived HTML as the source of truth.

## Software planning workflow

Run these stages in order. Read each owner completely when its stage begins.

1. **Intake.** Follow `references/software/intake.md`. Resolve the repository,
   source contract, target outcome, plan path, output adapters, and any true
   product blocker.
2. **Ground the current system.** Read and follow
   [references/software/grounding.md](references/software/grounding.md).
   Inspect repository rules, relevant architecture, implementation, tests,
   dependencies, and prior decisions. Distinguish facts, inferences, and
   proposed technical decisions.
3. **Design the change.** Read and follow
   [references/software/technical-design.md](references/software/technical-design.md).
   Describe current and target behavior, select an approach, and address each
   material system boundary and risk.
4. **Build the work graph.** Read and follow
   [references/software/work-units.md](references/software/work-units.md).
   Define stable implementation units, blocking edges, integration order, and
   unit-level acceptance.
5. **Define proof.** Read and follow
   [references/software/verification.md](references/software/verification.md).
   Map requirements and risks to test scenarios, commands, rollout checks, and
   the Definition of Done.
6. **Write Markdown.** Read and follow
   [references/adapters/markdown.md](references/adapters/markdown.md). Write the
   canonical artifact or return the same structure in chat.
7. **Review.** Read and follow
   [references/software/final-review.md](references/software/final-review.md).
   Fix safe plan defects directly. A product decision or material technical
   tradeoff that lacks authority remains a visible blocker.
8. **Run requested adapters.** Read
   [references/adapters/beadwork.md](references/adapters/beadwork.md) only for
   an explicit Beadwork request. Read
   [references/adapters/html.md](references/adapters/html.md) only for an
   explicit HTML request. Run Beadwork before HTML.
9. **Final consistency check.** Recheck Markdown after adapter updates. When
   HTML exists, confirm it represents the final Markdown. Report any adapter
   that did not complete without downgrading a valid Markdown plan. Reapply the
   Adapter review section in `references/software/final-review.md`.

Do not require a subagent, external model, companion skill, issue tracker,
browser, or special host feature. Use available tools when they improve direct
evidence. A missing optional capability produces a named limit, not a false
success.

## Handoff

Report:

- the absolute Markdown path or that the plan is in chat;
- `implementation-ready` or `planning-blocked`;
- the key technical direction and first unblocked units;
- HTML path and Beadwork IDs when requested and completed;
- unresolved decisions, unsupported facts, and skipped checks; and
- the next executor and granted authority that the plan assumes.

For an implementation-ready plan, include this host-neutral handoff:

```text
Implement <absolute-plan-path> to its Definition of Done. Follow the unit
dependency order, preserve the Product Contract and Key Technical Decisions,
run the Verification Contract, and record progress outside the plan file.
```

Do not start that work unless the current request separately authorizes
implementation.
