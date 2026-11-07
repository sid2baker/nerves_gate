---
name: kata-roadmap
description: "Create and advance a durable decision roadmap. Use when the destination is clear but dependent decisions are too uncertain or long for one planning session. Require Beadwork or CSV; use implementation planning when the decisions are resolved."
metadata:
  kata-argument-hint: "[initiative, Product Contract, or roadmap ID/path] [backend:beadwork|csv] [operation:create|advance|status]"
  schema: kata.skill/v1
  subject: general
  practice: roadmap
  object: initiative
  profile: direction
  authority: local-write
  consumes: "initiative-request, idea-brief, product-contract, understood-context, decision-roadmap"
  produces: "decision-roadmap, planning-request, verified-change"
---

# Roadmap a Long-Horizon Initiative

**Outcome:** The accountable owner and next planner receive a durable decision
roadmap that shows the destination, time horizon, resolved decisions, current
frontier, dependencies, remaining uncertainty, and review points for one
long-horizon initiative.

**Done:** The requested operation has a verified Beadwork or CSV result. A
created roadmap has a clear destination and actionable frontier. An advance
resolves or explicitly blocks one frontier decision and reconciles the
roadmap. A status run reports the saved state without changing it. A completed
roadmap has no open decisions or unspecified in-scope territory and provides a
planning handoff.

## Assignment and authority

The required input is one clear initiative, Product Contract, idea brief, or
existing roadmap. The assignment must identify the accountable owner, intended
destination, time horizon, acceptance condition, available resources, and
review point. The time horizon is how far ahead the decisions must remain
useful, not how long the current agent run lasts.

Direct user authority or inherited caller authority permits read-only research
and local writes to one selected roadmap backend. It also permits a derived
local planning handoff when the roadmap completes. Preserve unrelated and
concurrent work.

Do not edit product code, implement the destination, initialize or repair
Beadwork, synchronize Beadwork, create a branch or commit, change remote state,
publish an artifact, invoke another skill as a required step, or change a live
system. A prototype or enabling task can change another local artifact only
when the assignment grants that added authority. Otherwise, record a precise
handoff and keep the decision open.

Ask the accountable owner when a missing decision can change the destination,
scope, success condition, time horizon, authority, cost, stored data, public
contract, security boundary, or irreversible effect.

## Activation boundary

Use this skill when the destination is clear but the route contains dependent
decisions that need more than one review cycle or agent session. The roadmap
owns decision resolution across time. It does not own implementation design or
execution.

- Use idea work when the beneficiary, destination, scope, or success condition
  is still unsettled.
- Use implementation planning when the material decisions are settled and the
  remaining job is technical design, sequencing, tests, or rollout.
- Skip a roadmap when one planning session can resolve the full route without
  hidden uncertainty.

An explicit invocation can return `roadmap-not-needed` when evidence shows that
the route is already clear. In that case, return the supported planning input
and do not create empty state.

## Roadmap model

Read [references/roadmap-contract.md](references/roadmap-contract.md) before
creating or changing roadmap state. It owns the record fields, stable IDs,
decision kinds, lifecycle, frontier, fog, scope, and completion rules.

Keep decision work separate from implementation work. A roadmap item asks a
question or gathers the evidence needed to answer one. An item that builds part
of the destination belongs after the roadmap.

Each advance resolves one selected decision by default. Independent research
can run concurrently when the environment supports it, but do not close a
second decision only because its evidence arrived during the same run. Each
decision closure is a review point.

## Select the operation and backend

Select one operation:

- **Create:** No roadmap exists. Establish its contract and initial frontier.
- **Advance:** A roadmap exists. Resolve one named decision or the first
  available frontier decision.
- **Status:** Read and report the current state without changing it.

Read [references/issues.md](references/issues.md) before selecting storage. It
owns the repository-wide `docs/agents/issues.md` contract and the command gates
for local and remote issue systems.

Every created roadmap requires exactly one currently supported backend:

- `backend:beadwork` uses an installed, already initialized local Beadwork
  repository.
- `backend:csv` uses one local CSV file and permits only one active writer.

Infer the backend from an existing roadmap reference or a clear
`docs/agents/issues.md`. For a new roadmap, honor an explicit Beadwork or CSV
backend and record it in that repository document. When the document is absent,
prefer readable initialized Beadwork only when the repository convention makes
that choice clear. Otherwise ask for Beadwork or a CSV path. If parallel
writers are possible, do not use CSV; require Beadwork.

GitHub Issues through `gh` and Jira Issues through `twg` are queued repository
backends, not current roadmap backends. Do not use them until their adapters
and repository guidance pass the gates in `references/issues.md`.

Read [references/beadwork.md](references/beadwork.md) after selecting Beadwork.
Read [references/csv.md](references/csv.md) after selecting CSV. If neither
backend can meet its preconditions, return `roadmap-blocked` without creating a
partial substitute.

## Create

1. **Establish the assignment.** Confirm the destination, acceptance condition,
   accountable owner, target date or event, review point, authority, resources,
   and scope boundary. Use supplied idea or Product Contract decisions without
   reopening them.
2. **Inspect current evidence.** Read only the repository, documents, history,
   and sources needed to avoid questions that available facts can answer.
3. **Find the initial decision frontier.** Work breadth-first across the
   initiative. State each sharp open question now. Keep a suspected area as fog
   when its exact question depends on an unresolved decision.
4. **Classify each decision.** Select discussion, research, prototype, or
   enabling task. Name its interaction owner, dependencies, expected evidence,
   and review point.
5. **Write state.** Create the roadmap container first, then decision records,
   then dependency edges. Use stable roadmap IDs before backend IDs.
6. **Read state back.** Verify the destination, initial frontier, blockers,
   fog, scope, IDs, and backend invariants. Stop without resolving a decision.

## Advance

1. Load the roadmap container and saved decision index. Do not load every
   resolved decision unless the selected item depends on it.
2. Recompute the frontier from saved status and dependency state. Use the
   named item when it is open and unblocked. Otherwise, select the first
   unclaimed frontier item in stable ID order.
3. Claim the item before work. Record the executor and review point. Do not
   take a blocked item or another executor's active item.
4. Resolve the item by its kind:
   - **Discussion:** Put the accountable choice to the human. Do not answer for
     the human.
   - **Research:** Gather direct evidence from authoritative sources. Record
     sources and limits with the answer. If one evidence method fails, use
     another supported method within the decision scope and resource limit.
   - **Prototype:** Produce only the smallest authorized throwaway artifact
     that can answer the stated question. Record the verdict, not prototype
     code, as the decision.
   - **Enabling task:** Perform only the authorized prerequisite needed to make
     a decision possible. It must not deliver part of the destination.
5. Record one resolution and its evidence in the selected item. Close it, add
   a one-line indexed result to the roadmap, and preserve the detailed answer
   in only one place.
6. Recompute the route. Add newly sharp decisions, graduate clarified fog,
   update invalidated dependencies, and move work beyond the destination to
   out of scope.
7. Read state back, repair in-scope record defects, and verify the new frontier.
   Stop after this decision.

When the selected decision needs a human answer that is not available, leave
it claimed only when the backend can preserve that claim safely. Otherwise,
return it to open. Report the exact question, owner, and affected frontier.

## Status

Read the backend without changing it. Report:

- destination, accountable owner, target, and next review;
- backend identity and roadmap status;
- resolved, open, active, and out-of-scope counts;
- current frontier and blocked decisions by name;
- remaining fog;
- decisions whose review point has passed; and
- the next accountable action.

## Completion and handoff

Complete a roadmap only when:

- its destination and acceptance condition still match the assignment;
- every in-scope decision is resolved;
- no in-scope fog remains;
- every resolution has evidence or a named accountable decision;
- no dependency or active claim remains; and
- the decision set is sufficient for the next planner without invention.

Mark the backend roadmap complete and return a `planning-request` that names
the roadmap, destination, fixed decisions, constraints, sources, and target
repository or delivery context. Do not create implementation units in the
roadmap and do not start planning unless the current request separately grants
that work.

Report the operation, backend, roadmap ID or path, status, frontier, decision
resolved in this run, state verification, remaining fog or blockers, next
review, and next consumer.
