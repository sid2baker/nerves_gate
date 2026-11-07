# Decision Roadmap Contract

Read this contract before creating or changing a roadmap. The roadmap records
the route from a fixed destination to a planning-ready decision set. It is not
an implementation backlog.

## Roadmap container

Keep one container with these fields:

- **Roadmap ID:** A stable local ID that does not depend on a backend ID.
- **Title:** A short name for the initiative.
- **Destination:** The observable state that ends the roadmap.
- **Acceptance:** The evidence that the destination is decision-ready.
- **Accountable owner:** The person or role that accepts decisions and grants
  authority.
- **Time horizon:** How far ahead decisions must account for effects.
- **Target:** A date or named event. Do not invent one.
- **Review point:** The next date, event, or decision boundary for review.
- **Authority and resources:** Limits, available evidence, tools, budget, and
  dependencies.
- **Decisions so far:** One-line result and pointer for each resolved decision.
- **Fog:** In-scope territory whose exact question is not yet sharp.
- **Out of scope:** Work beyond the destination, with the reason.
- **Status:** `active`, `complete`, or `blocked`.
- **Backend:** `beadwork` or `csv`, plus its ID or path.

The container is a low-resolution index. Keep the full question, evidence, and
resolution in the decision record. Do not copy the detailed answer into the
container.

## Decision records

Assign `D1`, `D2`, and later IDs in creation order. Preserve an ID while its
question has the same meaning. A split creates new IDs and records the old-to-
new relation. A removed or superseded decision stays traceable.

Each decision contains:

- **Title:** A readable name used in reports.
- **Question:** One precise answerable question.
- **Kind:** `discussion`, `research`, `prototype`, or `enabling-task`.
- **Interaction:** `human` or `agent`.
- **Status:** `open`, `in_progress`, `resolved`, or `out_of_scope`.
- **Blocked by:** Stable decision IDs whose answers are required first.
- **Owner:** The executor for active work or accountable decision-maker for a
  human choice.
- **Review point:** The target date, event, or parent decision boundary.
- **Expected evidence:** What permits closure.
- **Resolution:** The answer and its consequences.
- **Evidence references:** Paths, issue IDs, URLs, commits, or observations
  that support the resolution.
- **Backend ID:** The Beadwork ID or CSV row identity.

Do not use `blocked` as a saved status. A decision is blocked when one or more
IDs in `Blocked by` are not resolved. This keeps the state derived from the
graph.

## Decision kinds

- **Discussion** resolves an accountable preference, policy, or tradeoff. A
  human-interaction decision cannot close without the named human's answer.
- **Research** resolves a factual uncertainty. Prefer primary sources and
  current repository evidence. State uncertainty and source dates when they
  affect the answer.
- **Prototype** creates a cheap, disposable artifact only to answer its
  question. A prototype does not become product code through this roadmap.
- **Enabling task** performs necessary work before a decision can be made. If
  it delivers part of the destination, it is implementation work and must move
  out of the roadmap.

## Fog, scope, and frontier

Fog is not a weak decision record. Keep territory in fog when you cannot yet
state one precise question. A decision can be open even when you cannot answer
it now; answerability, not current knowledge, separates a decision from fog.

The frontier is every decision that is:

- `open`;
- not blocked by an unresolved decision; and
- not claimed by another executor.

Refer to decisions by title. Include the stable ID or backend link with the
title, not instead of it.

Move an item beyond the destination to out of scope. Record why and preserve
its pointer. Do not count an out-of-scope item as a resolved route decision.

## Graph and completion invariants

The decision graph must be acyclic. Every blocker must exist in the same
roadmap. A resolved decision has a resolution and evidence reference, or it
records the named accountable human decision that supplies the evidence.

The roadmap completes only when the frontier, blocked set, active set, and fog
are empty and all in-scope decisions are resolved. Completion creates a
planning handoff. It does not create implementation tickets.
