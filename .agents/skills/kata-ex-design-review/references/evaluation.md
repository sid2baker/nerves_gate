# Evaluate the review skill

Use this procedure when changing the skill. Keep project-specific results outside
this directory so the published skill stays independent of one package.

## Compare runs

1. Select a fixed revision of an Elixir package with several responsibilities.
   Record the source state, runtime versions, allowed tools, and review request.
2. Run the current and proposed skill with the same scope and check budget.
   Use fresh contexts when available. Do not give the reviewer an answer key.
3. Keep each coverage table, finding, temporary reproduction, rejected hypothesis,
   and tool result. Separate results reused from an earlier run.
4. Have a maintainer verify each finding against the contract. Record missed
   defects and unsupported findings. Do not score report length or finding count.
5. Repeat on another package before claiming that the change improves reviews
   in general. One successful run is evidence for that run only.

## Acceptance cases

| Scenario | Required evidence |
| --- | --- |
| Repeat a full package request after a focused review | All package responsibilities remain in scope. |
| A previous fix changes one error adapter | Related adapters are inspected for the same assumption. |
| Generated modules always return map-shaped error details | A valid custom implementation is checked; no undocumented map requirement is assumed. |
| A monitored process fails before its owner waits | A deterministic probe leaves the original monitor event queued and checks the reported reason. |
| An existing test consumes the monitor event first | The reviewer distinguishes that case from an event still in the mailbox. |
| Large modules, one-implementation behaviours, or dependency cycles | No redesign is proposed without a concrete contract or maintenance cost. |
| Full tests pass but a review area is pending | The reviewer continues or reports a concrete blocker and a partial verdict. |
| A suspected defect is disproved | The candidate is dropped; no replacement finding is forced. |
| Broad review with native subagents | Assign bounded responsibilities; verify every returned claim and close all coverage rows. |
| Narrow review | Avoid an automatic full roster. |
| Subagent tools or capacity unavailable | Complete the assigned work inline and state the substitution. |
| Several reviewers agree | Confidence follows evidence, not vote count. |
| All reviewers return no findings | Check coverage and preserve justified design; do not demand more issues. |
| Repeated lesson or unfixed defect | Update an existing rule only when authorized; do not record an unverified solution. |
| Review-only request | Package source and configuration stay unchanged. |
| A small fix introduces a generic boundary module | Compare deletion, local changes, and an existing owner before retaining it; repeated syntax alone is insufficient. |
| Existing error handling already covers a failure | Preserve its contract; do not add a second policy merely for uniformity. |
| Two waits can become one receive | Verify queued events, death during the wait, deadlines, and cleanup before accepting the reduction. |
| Removing a helper would duplicate a required rule | Keep or place the rule in its existing owner; explain why further deletion would weaken the contract. |
| A fix adds required validation or cleanup | Accept justified growth; count production, tests, and docs separately against the pre-edit state, including untracked files. |
| A shorter patch compresses syntax or removes useful tests | Reject the reduction; behavior and readability remain required. |
| A macro stores caller terms | Escape first, walk the escaped form for forbidden runtime literals, and compile direct/nested valid and invalid cases with source-line errors. Preserve allowed remote captures and improper lists. |
| A sanitizer passes map and keyword tests | Probe mixed/improper lists, tuples, structs, exceptions, nesting, limits, and every output profile; verify secret absence at actual error, Logger, telemetry, or status boundaries. |
| Unsubscribe, death, and replacement change one target | Identify one transition owner; verify idempotent cleanup, detach-before-attach order, and exact event counts with deterministic synchronization. |
| A documented value passes construction | Compare public types, runtime validation, normalization, serialization, round trips, and runnable examples for the same value, including invalid cases. |
| An earlier fix passes its regression test | Challenge missed shapes, event orders, sibling paths, and added complexity; retain or reopen the decision with evidence. |
| A clean full pass on an unchanged final state | Close coverage and verify prior decisions and required checks; accept convergence without forcing a finding. |
| The last authorized round applies a fix | Stop at the round limit; report verification and lack of a full final-state review. Do not claim convergence from passing tests. |
| A review resumes after context loss | A saved ledger identifies source states, stable decisions, evidence, verification, deferred choices, and reopening conditions; preserve decisions unless new evidence changes them. |

A run fails the scope check if it silently narrows a package request. It fails
the evidence check if a claimed defect has no reachable trigger or contradicts a
verified contract. Passing these checks does not prove the package has no bugs.
