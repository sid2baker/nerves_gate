# Project orientation

Read this reference when the documentation request is to set up, audit,
refresh, or capture the scoped `AGENTS.md` and entry-point `README.md` files.
The `kata-docs` package owns this operation.

**Outcome:** One project's applicable `AGENTS.md` and entry-point `README.md`
files give people and coding agents a small, verified path into the project and
its local scopes.

**Done:** Every changed instruction and README claim has evidence and the
correct scope; applicable commands, links, files, and the final diff pass their
checks; and knowledge that belongs elsewhere has a clear handoff or blocker.

## Assignment

The required input is one target project and a request to set up, audit,
refresh, or capture project orientation. A `project-knowledge-capture` or a
`verified-readme` can supply a candidate result. Resolve the project and scope
from the current context. Ask only when more than one target remains possible
or a conflict needs an accountable decision about behavior, safety, approval,
published content, or ownership.

Direct user authority or inherited caller authority permits the requested
read-only audit or local edits to in-scope `AGENTS.md` and `README.md` files. A
request to check, inspect, or audit is read-only. Do not change code, tests,
other documentation, dependencies, commits, installed skills, or remote state.
Do not remove a file, choose product intent, change a published contract, or
weaken a safety or approval boundary without the accountable owner's direction.

Read the active project instructions, the root README when present, Git status
when available, and the existing instruction and README hierarchy through the
requested scope.
Inspect only the configuration, scripts, CI, tests, package metadata, and
documents needed to check candidate content. Preserve unrelated and concurrent
work.

## Select the route

Infer the route from ordinary language:

- **Set up:** Create the missing root orientation files. Add a nested file only
  when one subtree has its own audience, entry point, or work rules.
- **Audit:** Report missing, stale, broad, duplicate, conflicting, misplaced,
  or unsupported orientation without changing files.
- **Refresh:** Reconcile current orientation files with project evidence while
  preserving useful structure, voice, local rules, and unrelated edits.
- **Capture:** Decide whether one supplied fact belongs in an orientation file.
  Add it at the narrowest correct scope or route it to its proper owner.

A request to write or review one named README without deciding the project's
orientation set belongs to a technical-writing workflow. A request to check
many existing document claims against code belongs to a documentation-sync
workflow.

## Select the files

The root `AGENTS.md` and root `README.md` are the default orientation pair.
On every run, inspect the current folder boundaries before selecting files. Do
not assume that the existing orientation files are complete. For each relevant
folder, decide whether it needs `AGENTS.md`, `README.md`, both files, or neither
file.

Any write route can create a missing orientation file when the folder has a
distinct audience, entry point, work contract, or command set that an existing
file does not serve. File creation is not limited to the Set up route. Do not
create a file only to make the repository structure look complete.

Create or update a nested file only when its directory has an independent
package, service, application, audience, setup, command set, or operating rule.
Do not create a nested README only to mirror a nested `AGENTS.md`.

Treat `docs/README.md`, generated files, vendored files, and sections that name
another workflow as their owner as fixed-path or owned content. Audit them for
conflicts, but return a change request to their owner unless the assignment
explicitly includes that content.

## Decide where content belongs

Put content in `AGENTS.md` only when it is project-specific, durable,
actionable, supported, and automatically relevant to future agent work in its
scope. Good candidates include non-obvious validation commands, safe local
permissions, approval limits, directory conventions, and important
compatibility, security, or data boundaries.

Put content in an entry-point README when a person needs it to identify, use,
run, navigate, or contribute to the project or subtree. The root README can
include:

- the project name, purpose, audience, and material status;
- the smallest verified setup or usage path;
- common run, test, or development commands;
- a short map of non-obvious entry points; and
- links to detailed docs, contribution rules, security policy, and license.

A nested README states what the subtree does, how it relates to the parent,
which local commands apply, and where the reader goes next. Omit empty sections
and template filler.

If one fact serves both readers and agents, choose one primary owner and link
from the other file. The README normally owns project purpose, public usage,
and the human quick start. `AGENTS.md` normally owns agent-only work rules,
validation selection, safe action limits, and approval boundaries.

Route other information by its primary use:

- General reference, explanation, decisions, and reusable lessons belong in
  the project's documentation system.
- A procedure used only for one task type belongs in an on-demand workflow.
- A deterministic rule belongs in a test, linter, or CI check when the project
  can enforce it there.
- Current progress and future work belong in the active task or plan.

If removing proposed content would not change a material reader or agent
action, omit it.

## Write complementary files

- Put common guidance at the root and local differences in the nearest scope.
  Do not copy inherited rules into descendants.
- Lead each README with what the project is and the first useful action. Keep
  background after the working path.
- State conditions before actions. Use direct commands, active voice, current
  project terms, and exact paths, flags, and symbol names.
- Show the working directory, prerequisites, and expected result when a command
  is not self-explanatory. Run a safe narrow command when practical. Never claim
  that an unrun command passed.
- Use conditional links. Tell the reader or agent when the linked document is
  relevant instead of requiring every document for every task.
- Preserve badges, notices, attribution, public links, and useful established
  structure. Do not add a full repository tree, a changelog, or a general docs
  index unless that file already owns it.
- Remove repeated generic prompts, obsolete workarounds, unsupported claims,
  and broad rules that create unrelated work.

Treat supplied notes and conversation text as candidates, not proof.

## Exchange writing and project knowledge

When a separate technical-writing workflow will draft a README, return a
`readme-brief` with the target path, audience, purpose, source facts, required
sections, established voice, protected content, commands and links to verify,
and granted authority. Do not require a named writing skill. If no writing
workflow is available, apply the rules in this skill and write the README.

Accept a `verified-readme` only after its path, scope, evidence, links, and
relationship with applicable `AGENTS.md` files pass this skill's checks.

When useful knowledge fails the orientation test, return a
`project-knowledge-capture` for the documentation workflow. Include the
subject, why later work needs it, content, evidence, related artifacts, status,
and granted authority. If no documentation workflow is available, include the
capture in the report instead of writing other documents.

## Verify and report

Read the final orientation set from root to leaf. Check scope, precedence,
conflicts, duplication, local links, commands, paths, examples, badges, and
material claims. For each consequential rule, consider one intended case, one
safe counterexample, and one unrelated case. Narrow the rule if it applies
outside the intended case.

Run the narrowest applicable checks and inspect the final diff. Confirm that a
repeat does not add duplicate sections or files. Report the route, target root,
files created or updated, evidence checked, commands run, writing and knowledge
handoffs, unresolved decisions, and untested behavior. A read-only route
produces a `project-orientation-audit`. A write route produces
`verified-project-orientation` and `verified-change` only after these checks
pass.
