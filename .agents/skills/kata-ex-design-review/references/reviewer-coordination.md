# Reviewer coordination

Use independent reads to reduce missed contracts. More reviewers and more
findings are not measures of review quality.

## Select the work

The primary reviewer first fixes the source revision and builds the coverage
table. For a full package with separable responsibilities, select two or three
reviewers from the lenses below. Use fewer when the package has fewer independent
risks. For a narrow scope, review inline; add one independent reviewer only for a
specific unresolved risk. Respect an explicit user request to work alone.

| Lens | Assign when | Questions |
| --- | --- | --- |
| Contracts and composition | Multiple public entry points, constructors, callbacks, or storage forms | Do equivalent inputs preserve results, errors, effects, and validation across boundaries? Do valid custom implementations work? |
| OTP and execution | Processes, tasks, state transitions, deadlines, or cancellation | Who owns work and state? What happens before, during, and after failure or completion? Are cleanup guarantees real and documented? |
| Design and maintenance | Several abstractions, authoring layers, or repeated rules | Which concepts earn their cost? Can a verified simplification remove a maintenance burden without weakening the contract? |

Assign each coverage row one primary owner. Give reviewers bounded paths and the
caller/callee seams they must trace. Allow deliberate overlap at risky boundaries,
but do not ask every reviewer to audit the entire package. The primary reviewer
traces composition between assignments and inspects uncovered rows.

## Dispatch brief

Give every reviewer this reference and the review-lenses reference, plus:

- Repository path, exact revision, included local changes, and assigned rows.
- Applicable instruction paths, supported runtime versions, and contract sources.
- Entry points, relevant implementation/test paths, and explicit non-goals.
- Report-only authority: no package edits, commits, dependency installs, or live
  changes. No further delegation. Coordinate checks with the primary reviewer.
- The return contract below. An empty finding list is a valid result.

Prefer a fresh context with a neutral brief. Do not seed the first independent
pass with the primary reviewer's suspected findings or previous verdict. Pass
verified requirements and deliberate tradeoffs so independence does not become
ignorance of the contract. Prior fixes can be checked separately after that pass.
If the platform cannot isolate context, state the limit; do not claim full
independence. Inherit the configured model unless the user selects another.
Independent contexts are not evidence of independent model reasoning.

Use only the platform's native subagent tools. Announce the assignments, respect
its active-agent limit, and collect every assigned outcome before synthesis.
Use completion waits rather than shell polling. Do not invent tool names or
change permissions. If tools or capacity are unavailable, complete those rows
inline and disclose the substitution. Never treat a failed dispatch as coverage.
The primary reviewer owns broad test runs; reviewers request costly or conflicting
checks instead of running duplicate builds against shared state.

## Return contract

Return concise structured Markdown; no separate JSON machinery is required:

1. **Coverage:** assigned rows, paths read, success/failure traces, checks, gaps.
2. **Findings:** class, priority, confidence, exact location, reachable trigger,
   expected/actual behavior, consequence, smallest alternative, compatibility risk,
   and reproduction or verification method. Name code or concepts to remove;
   justify any added structure against a smaller local fix. Refinements need a
   concrete cost. Do not propose extra findings or helpers to fill the assignment.
3. **Preserve:** sound choices and important constraints.
4. **Rejected hypotheses:** material candidates disproved by evidence.
5. **Learning candidate:** at most one reusable lesson, with evidence and limits;
   omit when the existing guidance already covers it.

Keep detailed probe output in task-specific temporary files when needed and
return their paths with the result summary. A path alone is not a finding. If a
scratch write fails, return the evidence inline. Never write a package report
unless the user requested one.

## Verify and synthesize

The primary reviewer reads each return, resolves gaps, and merges findings by
root cause. Agent agreement does not raise confidence by itself. Reproduce
claimed defects or verify their reachable paths; assess refinements against
change cost and existing contracts. Resolve disagreements with evidence. Keep
unresolved questions as investigations, not defects.

For a disputed or high-impact claim, request a focused counter-check from a
reviewer who did not propose it. Give the claim and ask for evidence that could
refute it; label this as validation, not independent discovery. Do not create a
second full review roster just to validate a small result set.

Return one assessment with actual reviewer coverage and substitutions. Apply the
main skill's completion rule even when all agents report no findings. Capture
only distinct lessons: update an existing rule or evaluation case rather than
adding a new persona or process for every issue. Do not claim a fix is verified
when the run only demonstrated the defect.
