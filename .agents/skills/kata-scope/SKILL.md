---
name: kata-scope
description: Turn a rough request into bounded delivery work with a clear outcome, exclusions, completion evidence, dependencies, and open decisions. Use when the user says they want to scope work or when boundaries are unresolved; do not create a roadmap, implementation plan, or worker assignment.
metadata:
  kata-argument-hint: "[request, outcome, or source context to scope]"
  schema: kata.skill/v1
  subject: general
  practice: scope
  object: work-request
  profile: direction
  authority: local-write
  consumes: "rough-request, understood-context, idea-brief, product-contract"
  produces: "work-brief, scoped-work"
---

# Scope Work

**Outcome:** The work owner and next worker receive the smallest useful work
brief that states the intended result, boundaries, completion evidence, and
decisions that still need an owner.

**Done:** The brief distinguishes agreed facts from proposals, defines what is
included and excluded, supplies enough acceptance evidence to start the next
step, and names every material gap without inventing an owner or commitment.

## Assignment and authority

The required input is one rough request, outcome, understood problem, idea
brief, or product contract. Use this skill when the user says “scope this,” or
when the intended result is clear but its delivery boundary is not.

Direct user authority or inherited caller authority permits read-only
inspection and local writing of the requested work brief. Do not execute the
work, assign a person or agent, create project-tracker state, send a message,
change a live system, publish, commit, or make a remote write. A scope request
does not grant those actions.

Ask one short question only when the missing answer can materially change the
outcome, boundary, acceptance condition, authority, cost, risk, or owner. Use a
clearly labeled proposal for a reversible boundary when that lets the work
advance without claiming agreement.

## Set the boundary

1. **State the outcome.** Name the result and why it matters. Use an observable
   result instead of an activity such as “research,” “improve,” or “handle.”
2. **Identify the consumer.** Name who or what will use the result, when known.
   Do not invent a person, commitment, or deadline.
3. **Define included work.** List only the actions or result areas required for
   the outcome.
4. **Define exclusions.** State nearby work that could be confused with this
   assignment but is outside it.
5. **Set completion evidence.** Describe what the consumer can inspect to decide
   whether the result is done. Keep subjective decisions with their owner.
6. **Record inputs and dependencies.** Name required sources, prior decisions,
   external conditions, and known owners. Mark missing values as unknown.
7. **Divide only when useful.** Create bounded delivery units only when separate
   ownership, dependencies, review, or risk makes the division useful. Do not
   split a small coherent task for ceremony.
8. **Surface risk and open decisions.** Include rollout or recovery needs only
   when the work can change state that may need reversal.

Read [references/work-brief.md](references/work-brief.md) for the portable
output and compact form. Use the compact form when it can carry the full
contract.

Resolve available facts before handoff. If an owner decision is unavailable,
state the blocker. Do not start delivery or weaken acceptance conditions to
make the brief ready.

## Respect adjacent owners

- Use idea work when the desired behavior, beneficiary, or success signal still
  needs an accountable product decision.
- Use a roadmap when dependent decisions must be resolved across several
  review cycles.
- Use software planning when selected software work still needs technical
  design and sequencing.
- Use delegation when defined work needs worker assignments and follow-through.
- Start execution directly when target, boundary, acceptance, and authority are
  already clear.

Do not force an issue tracker, project hierarchy, roadmap, or implementation
plan. Scope defines what can enter delivery. It does not define every technical
step or supervise the return.

## Report

Return the work brief, agreed and proposed boundaries, unresolved decisions,
known owners, and the recommended next owner. State `scope-ready` when the next
worker can act without guessing. State `scope-blocked` when an accountable
decision is required. A clear task that needs no new boundaries can return
`scope-not-needed` with the supported work request.
