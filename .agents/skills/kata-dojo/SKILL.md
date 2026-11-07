---
name: kata-dojo
description: Use only when the user explicitly requests Dojo. Inspect saved evidence or evaluate one exact skill candidate with controlled cases; do not use for ordinary skill development, verification, adoption, commits, or publication.
metadata:
  kata-argument-hint: "[skill candidate, suite, or saved evaluation context]"
  schema: kata.skill/v1
  subject: agent-work
  practice: evaluate
  object: skill-candidate
  profile: bounded-execution
  authority: local-write
  consumes: "conforming-skill-package, skill-evaluation-suite, skill-evaluation-request"
  produces: "skill-evaluation-evidence, adoption-recommendation, verified-change"
---

# Dojo

Do not activate this skill from an inferred need for evidence. The user must
explicitly name Dojo in the current request. A request to write, test, verify,
review, or improve a skill does not activate Dojo.

**Outcome:** The acceptor or next consumer receives reproducible evidence about
one exact skill candidate and a bounded adoption recommendation.

**Done:** The candidate, cases, checks, execution profile, costs, and evidence
level are identified. Each executed case has an outcome, and the result states
what the evidence proves and does not prove.

## Assignment

The required input is one candidate skill or saved evaluation context. A live
run also requires a fixed suite with representative tasks and independent
outcome checks. Resolve the decision that the evidence must support before any
execution.

Direct user authority or inherited caller authority permits read-only
inspection and local isolated evaluation artifacts. Live model calls require an
explicit request for a live Dojo run, an execution profile, a call or token
limit, and authority for the cost. Do not infer a paid budget from a request to
inspect saved evidence. Do not edit the official source skill, adopt a
candidate, commit results, publish an artifact, or change remote state.

The normal profile is `bounded-execution`. Creating or repairing a reusable
suite is a separate `system-design` assignment and must not be hidden inside a
candidate evaluation.

This spike evaluates skills only. It does not claim to evaluate a generic play.
A later adapter can represent plays after their execution and outcome contracts
are stable.

## Enter at the first missing gate

Do not repeat valid saved work. Start at the first gate whose evidence is
missing or stale:

1. **Contract:** Fix the candidate identity, outcome contract, cases, checks,
   profile, writable paths, and limits.
2. **Baseline:** Run or locate a valid source result for the same contract.
3. **Training:** Run one bounded training case or tune with training feedback
   only.
4. **Verification:** Test one fixed candidate on cases excluded from tuning and
   use the required repetitions.
5. **Decision:** Compare complete evidence and prepare the acceptance handoff.

Any change to the candidate, task inputs, prompt, support files, profile, or
execution settings invalidates execution comparability. A checker repair can
reassess saved output, but it is not a new execution.

Within the approved budget, repair evaluation setup failures and rerun affected
cases without changing the candidate or evaluation contract. Report a missing
capability or exhausted budget as a blocker.

When the target repository contains the Kata Dojo runner, read
[references/kata-runner.md](references/kata-runner.md) before using it. If no
compatible runner exists, return the missing capability or prepare a separate
suite-design assignment. Do not invent runner commands.

## Judge the evidence

Use one of these results:

- **Retain source:** The candidate does not improve the complete evidence.
- **Adoption candidate:** The exact candidate passes all required outcomes and
  the promotion evidence supports it.
- **Rejected:** A required outcome is proven false.
- **Inconclusive:** Evidence is incomplete, incomparable, or awaits review.
- **Blocked:** A required capability, authority, or budget is unavailable.

Never let a median hide a failed required execution. Keep final-case evidence
out of tuning feedback. Do not turn shorter text or lower cost into success when
an outcome fails.

Produce `verified-change` only when an adoption-candidate verdict applies to the
exact candidate in the current local source package and all required evidence
matches that source state. This output reports verification evidence; it does
not record consumer acceptance or adopt a candidate from another path.

## Report

Report the candidate path and hash, source identity, suite and checker identity,
profile, cases and repetitions, outcomes, measured costs, saved evidence paths,
verdict, uncovered behavior, and recommendation. An adoption candidate is a
recommendation to the acceptor and the skill-writing owner. It is not adoption.
