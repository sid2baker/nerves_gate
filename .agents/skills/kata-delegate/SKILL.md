---
name: kata-delegate
description: Assign defined work to available people or agents and manage its return with clear authority, completion checks, and integration ownership. Use for delegation, worker coordination, or bounded check, watch, and drive follow-through; return a usable assignment brief when no delegation tool is available.
metadata:
  kata-argument-hint: "[defined work] [mode:assign|check|watch|drive]"
  schema: kata.skill/v1
  subject: general
  practice: delegate
  object: work-assignment
  profile: coordination
  authority: local-write
  consumes: "work-request, work-brief, scoped-work, assignment-status"
  produces: "work-assignment, returned-result, integration-handoff"
---

# Delegate Work

**Outcome:** Each useful unit of defined work has one responsible worker, clear
authority, a checked return condition, and an owner who can integrate or reject
the result.

**Done:** The assignment was either given to an available authorized worker or
returned as a usable brief. Every started assignment has a known state and stop
condition. Returned work includes evidence, changes, and unresolved questions
for its integration owner.

## Assignment and authority

The required input is defined work with an intended result, boundary,
completion conditions, and owner. If a material boundary is missing, return a
scope handoff rather than asking a worker to guess.

Preparing an assignment brief is permitted by direct user authority or
inherited caller authority. Starting a person, agent, service, or external job
requires an available tool and authority for that action. Sending a message,
creating a remote task, spending money, changing a live system, publishing,
merging, or making another remote write requires the matching explicit
authority. Do not claim that a worker started when only a brief exists.

Use the host's available worker and monitoring tools. Do not require one model,
agent API, issue tracker, or coding host. If no suitable tool is available,
return the complete plain-text assignment and the exact action still needed.

## Prepare the assignment

Read [references/assignment.md](references/assignment.md). Resolve:

- the intended result, purpose, source context, and expected output;
- one responsible worker and one integration owner;
- allowed actions, reserved decisions, and resource limits;
- inputs, dependencies, shared mutable state, and sequence constraints;
- completion checks, return evidence, and repair owner; and
- progress, blocker, decision, and stop conditions.

Delegate only when separate ownership or parallel progress provides clear
value. One worker is often sufficient. Independent work can run in parallel.
Tasks that edit shared state need separate ownership, isolation, or an explicit
sequence. More workers are not a success measure.

## Start and track work

1. Show or state the assignment before starting a worker when a material
   interpretation remains. Do not ask for confirmation when the request already
   authorizes the resolved assignment and action.
2. Start the smallest useful worker set. Record the actual worker or tool,
   assignment identity, start evidence, integration owner, and stop condition.
3. Do useful independent work while workers run when it does not conflict with
   their mutable state.
4. On return, compare the candidate with its assignment. Record evidence,
   changes, missing inputs, failed checks, and unresolved decisions.
5. Send a failed candidate to its work owner for repair only within existing
   authority. Send a completed candidate to the identified verifier or
   integration owner. Do not declare final acceptance from worker self-report.

In `drive` mode, retain responsibility through repair and the next checked
return. Change the approach within the assignment when a worker fails. Report
a blocker only when no further authorized action can make progress. Complete
the requested supervision result without claiming that a larger goal is
complete.

Jido owns integration when Jido called this skill. A direct caller must name an
integration owner or receive that responsibility in the handoff. Material scope
changes return to the scope owner. Consequential decisions return to the human.

## Supervise follow-through

Read [references/supervision.md](references/supervision.md) for `check`, `watch`,
and `drive`. A bare status request permits one check. Starting work does not
automatically authorize continuing observation or corrective follow-up.

Keep the selected mode, target, stop condition, and resource limit visible.
Distinguish slow progress, a missing input, a worker failure, and a failed
completion check. Do not retry an unchanged failure. Avoid duplicate
supervisors and report meaningful changes instead of routine polling.

Domain-specific delivery stays with its owner. Git pull-request watching and
landing belong to the repository's shipping method. This skill does not infer
authority to commit, push, merge, publish, or send messages.

## Report

Return:

- assignment identity, worker, mode, and current state;
- result or usable brief;
- evidence and completion-check results;
- changed state and unresolved questions;
- repair, verification, and integration owners; and
- the stop reason or next authorized action.

Use `delegation-ready` for a complete unstarted brief, `delegation-active` for
authorized running work, `delegation-returned` for a checked return, and
`delegation-blocked` for a specific authority, tool, input, or decision gap.
