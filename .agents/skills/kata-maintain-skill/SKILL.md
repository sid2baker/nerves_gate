---
name: kata-maintain-skill
description: "Capture feedback on a skill or resolve one evidence-backed skill-library finding. Use when a skill misses the user's intent, needs improvement, or should retain useful behavior. Keep feedback local by default; use a skill-writing workflow when the package change is already defined."
metadata:
  schema: kata.skill/v1
  subject: agent-work
  practice: govern
  object: skill-library
  profile: system-design
  authority: local-write
  consumes: "skill-library, skill-feedback, skill-evaluation-evidence, conversation-history"
  produces: "feedback-brief, resolved-library-finding, conversion-brief, workflow-learning-brief, work-request, verified-change"
---

# Maintain Skill

**Outcome:** One actionable feedback brief or resolved library finding, with the
next owner and any permitted change clear.

**Done:** Exactly one feedback item or finding has a supported disposition or
an explicit evidence gap. Feedback ends in a local brief, shareable draft, or
confirmed authorized submission. A requested fix is complete and verified; a
handoff, failed check, or evidence gap does not complete it. A requested commit
workflow also reports its result. Unrelated concerns remain unchanged.

## Assignment

The operator can supply feedback, a finding, or Dojo evidence. A request such as
"feedback on shipit" selects the feedback entry below, not a library audit.
If neither feedback nor a finding is supplied, inspect the library and select
one. When supplied evidence already proves the finding, owner, and remedy,
do not repeat discovery or planning. Feedback can proceed without a source
checkout. For maintenance edits, work in the requested skill repository. Read
its active instructions, library rules, metadata conventions, current changes,
and affected packages before an edit.

Direct user authority or inherited caller authority permits local inspection
and the smallest local edit that resolves the finding. This can include skill
contracts, activation text, metadata, indexes, references, and documentation.
Do not install, publish, release, or change remote state, except for a feedback
submission explicitly authorized for its channel and destination. Get
explicit approval before a package deletion or rename, a license or provenance
change, execution of untrusted source, or a change that expands the assignment.

A request to complete the maintenance loop permits the in-scope local fix and
the required handoffs. This skill does not stage or commit changes. A commit
requires an explicit operator request and the canonical commit workflow. This
maintenance authority does not permit amend, rebase, push, merge, or other
remote or history-changing actions. The feedback entry has its own limited
feedback-submission authority.

The work profile is `system-design` when the finding changes a reusable library
contract or ownership boundary. It is `bounded-execution` when the finding only
repairs an established classification or index rule, or captures one feedback
brief without changing the library. Ask the accountable owner
when the decision depends on intent, rights, or authority that repository
evidence cannot establish.

When the operator explicitly asks to learn a reusable workflow or preference
from named conversations or a named date range, read
[references/chat-evidence.md](references/chat-evidence.md). Do not mine chat
history without that explicit source and range.

## Feedback entry

Use `feedback` as the entry word when the subject is a skill or its workflow.
Direct use: "Use kata-maintain-skill: feedback on this skill." A request to
review a report, design, or other unrelated result belongs to its own workflow.

Read [references/feedback.md](references/feedback.md) for every feedback request.
Capture the expected and observed results, relevant evidence, affected skill,
and next owner. Distinguish a reusable defect, execution failure, stale installed
copy, local preference, and useful behavior to preserve. Do not assume that
feedback proves a defect. Ask only for missing information needed to make the
feedback actionable; record unknown versions or unavailable source as unknown.

Feedback alone permits inspection and a brief in the current conversation.
It does not authorize changing a skill, updating an installed copy, storing a
personal preference, or sending feedback elsewhere. If the operator requests
a fix, continue through the existing finding and authoring routes below.

Keep the local brief as the default result. Do not assume the operator uses
GitHub. A local skill correction is a remedy, not a submission: explain which
copy changed, that the maintainer was not notified and the public pack was not
changed, and that updates may replace the edit. Account for linked sources.

Offer a copyable summary before external channels. If the operator wants to
share, use an available email address, GitHub issue, or verified feedback form.
Do not invent a recipient or offer a planned form as available. Prepare the
exact content and destination before the submission decision. Only explicit
opt-in permits sending; declining leaves the local feedback complete. Do not
create a separate feedback package.

## Select one finding

If the operator supplied a finding, test it before you accept it. Reuse matching
Dojo evidence only for the exact candidate and evaluation contract. Otherwise,
compare the declared library contract with the packages, indexes, and their
current callers. Select one issue with:

- a concrete consequence for safe use, routing, ownership, discoverability,
  rights, or maintenance;
- evidence in specific files or observed behavior; and
- a remedy that fits the granted authority.

If the finding concerns an early stop or incomplete follow-through, compare it
with the canonical continuation rules. Check recovery, unchanged retries,
completion claims, scope, authority, review points, and resource limits. One
finding can affect several packages when they share the same cause and the
requested scope includes them.

Prefer the finding with the highest likely harm and strongest evidence, then
prefer the smaller remedy. Do not select a style preference, a speculative gap,
or an issue that requires a broad audit to prove.

When a package can be out of date with the library contract, read the
repository's canonical skill-writing contract. In Kata, `kata-write-skill` owns
that contract. Report a conversion finding only when the gap can change the
outcome, activation, authority, classification, rights, verification, or next
consumer. A different heading or format is not sufficient evidence.

Write a short finding record before the change:

- **Observation:** What is inconsistent or ineffective.
- **Evidence:** What proves the condition.
- **Consequence:** Who or what receives the wrong result.
- **Canonical owner:** Which package or index must own the rule.
- **Disposition:** What this invocation will do.

Choose one disposition:

| Disposition | Condition |
| --- | --- |
| Refine | The canonical owner is correct, but its contract does not produce the required result. |
| Consolidate | Overlapping owners create an ambiguous route or duplicate rule. Keep one authoritative owner. |
| Reclassify | The package and the canonical index disagree about its work domain. |
| Retire | Evidence shows that the package is unsafe, obsolete, or has no distinct job. Approval is required. |
| Route | The finding proves a missing job or an existing package needs conversion to the library contract. Produce a bounded authoring brief for the maintainer. |
| Reject | The evidence does not prove a library defect. Make no change. |
| Defer | Required evidence, rights, or authority is unavailable. State the missing condition. |

## Resolve the finding

Apply only the selected disposition. Preserve unrelated edits, callers,
supported metadata, notices, licenses, and attribution. Keep each rule in one
canonical location. Use subject, practice, object, inputs, and outputs to find
overlap candidates. Then compare outcome, activation conditions, authority, and
next consumer. Do not consolidate packages only because their metadata, topics,
or tools are similar.

For a refinement, change the smallest contract text or support file that fixes
the proven consequence. For a consolidation, move the required behavior to the
canonical owner and update affected callers before an approved retirement. For
a reclassification, reuse the exact facet values used by equivalent work and
keep classification in the skill frontmatter. For a route, state the required
outcome, non-trigger, authority, taxonomy, acceptance evidence, and source
rights. If the operator requested a report only, stop with that brief. If the
operator requested a completed fix, use the canonical skill-writing workflow
for a skill-package change. Use the canonical work-execution workflow for
another clear local change, then use independent verification. Enter at work when
the finding already resolved the target, scope, acceptance conditions, and
authority; do not add understanding or planning steps. Return here with the
verification result.
For a conversion route, also name the behavior and resources to preserve and
the exact contract gaps to correct. Route Kata conversions to `kata-write-skill`
when it is available. Keep the brief complete when it is not available.

Do not fix a second finding. Mention another concern only when it blocks this
one.

## Complete the requested loop

When the operator requests a fix, a disposition or authoring brief is not
completion. Finish and verify the change. Repair failed checks within the
selected finding and authority, and change the approach when evidence rejects
the current one. Stop at an explicit review point, cancellation, a resource
limit, or an unavailable decision, authority, capability, or dependency that
prevents progress. Report the unmet condition, recovery attempted, and next
owner. Feedback-only and report-only requests end at the requested brief or
finding.

When the operator also requested a commit, pass the verified change to the
canonical delivery workflow. In Kata, use `kata-shipit` in Commit mode. Do not
stage or commit inside this skill. Report the returned commit hash or blocker.

Produce `verified-change` only when this invocation leaves a verified local
library mutation. A report-only, rejected, deferred, or routed finding does not
produce it.

## Verify and report

Check every changed name, frontmatter field, link, reference, caller, notice,
and subject entry that applies. Test changed activation, execution, or authority
behavior when the finding affects it. Use static checks only for a static index
or metadata repair. State the exact reason for any check that did not run.

Report the feedback or finding, disposition, canonical owner, evidence, changed
files, checks, and any blocker. For feedback, distinguish a local brief, an
unsubmitted draft, an authorized local remedy, and confirmed delivery evidence. Do not claim that the library is
healthy as a whole; the result covers one feedback item or finding only.
