---
name: kata-write-skill
description: Write one conforming agent skill package from an original request, external source, or existing skill. Use when a known package must be created, imported, or converted; use a library-maintenance skill when the required change is not yet known.
metadata:
  schema: kata.skill/v1
  subject: agent-work
  practice: build
  object: skill-package
  profile: system-design
  authority: local-write
  consumes: "skill-request, skill-source, conversion-brief"
  produces: "conforming-skill-package"
---

# Write Skill

**Outcome:** One focused skill package that fits the target library, states a
formal work contract, and is ready for the evidence level that its risk and
reach require.

**Done:** The package and taxonomy metadata pass their mechanical checks.
Required behavior has evidence proportionate to its risk and reach. The report
names each check and any unmet evidence. A blocked or partially checked
candidate remains incomplete. Mention Dojo only when the current request
explicitly names it.

Work in the requested skill repository. Read its active instructions, package
rules, README, and metadata conventions. Inspect current changes and preserve
unrelated work. Resolve the target and package name from the request. Ask only
when a missing decision can materially change the result or authority.

## Establish the assignment

Before a target change, resolve the decision-bearing facts:

- the objective, scope, expected output, and acceptance evidence;
- the authority granted for this invocation and the actions that still need
  approval;
- the source, destination, resources, time limits, and review points;
- the executor, accountable owner, acceptor, verifier, and maintainer when
  these roles affect the work; and
- the conditions that require escalation, handoff, or a stop.

One participant can hold several roles. A tool, source file, or skill is a
resource, not an accountable actor. The reusable skill describes supported
work. The current assignment grants actual authority. If a required fact is
missing, infer it only when the choice is safe, reversible, and does not change
scope or authority.

## Select one route

Classify source trust before you select an action:

- **User-owned:** Repository evidence or the user confirms control of the
  source and its license.
- **External with clear rights:** The source, revision, author, and compatible
  license are known.
- **Unclear:** Ownership, origin, or reuse rights are not proven. Treat this as
  external until the evidence is clear.

Then select one route:

| Route | Use it when | Required reference |
| --- | --- | --- |
| Create | No source skill exists and a real task or repeated failure supports a new skill. | [references/create.md](references/create.md) |
| Import | An external skill supplies behavior that the library will adopt. | [references/import.md](references/import.md) |
| Convert | An existing skill must meet this library contract, or a canonical skill needs a bounded revision. | [references/convert.md](references/convert.md) |

An external or unclear conversion must complete the import preflight before any
target change or source execution. Read only the selected route reference, plus
the import reference when that preflight applies.

When the requested package must drive a real application and preserve user-level
proof, also read and follow
[references/create-verification-skill.md](references/create-verification-skill.md).
This is a specialized Create route, not a separate library skill.

## Author from the library contract

Read [references/library-contract.md](references/library-contract.md) and
[references/authoring-principles.md](references/authoring-principles.md). Resolve
the formal contract before you edit the target. Use
[references/skill-template.md](references/skill-template.md) when the target
library has no stricter package shape. The final skill can combine fields when
their meaning stays explicit.

Write the outcome and one skill-level done condition before workflow. Apply the
authoring principles to activation, protocol, judgment, information placement,
pruning, authority, and verification.

For each package, define what happens after a failed check and when work must
stop. Keep the rule specific to the skill's role. Preserve report-only limits,
review points, authority, and resource limits.

Write the `kata.skill/v1` facets defined in the library contract. Reuse the
exact subject value used by skills in the same knowledge domain. Select the
subject by the specialist knowledge needed to judge the result, not by the tool
that performs the work. Use `general` only when acceptance does not materially
change by domain.

Keep the facets separate. Subject identifies the knowledge domain. Practice
identifies the kind of work. Object identifies the primary thing examined or
changed. Profile identifies the scope of judgment. Authority identifies the
normal action class but does not grant permission. `consumes` and `produces`
declare stable input and output types that small tools can use to derive
workflow candidates.

Do not file a skill by model, language, framework, or command name when those
are only implementation details. Do not assume that a longer run or the use of
delegated agents means that the work has a higher work profile.

## Build the package

Use a short, action-based, lowercase name with hyphens. Match the directory and
frontmatter name. Use standard `name` and `description` fields. Make the
description a selection pointer with clear triggers and non-triggers.

Keep the outcome, required protocol, load-bearing routes, bounded authority, and
done condition in `SKILL.md`. Put substantial branch-only or late material
behind a pointer that states when to read it. Add a script only when deterministic
work is fragile in prose. Add an asset only when it belongs in generated output.

Prune each instruction that does not add a falsifiable constraint, counter a
demonstrated failure, or supply a fact the agent cannot derive. Keep each rule
in one place. Do not restate configuration or directory facts that are cheap to
inspect. Preserve supported metadata, resource callers, safety rules, required
notices, and unrelated behavior during conversion.

Keep instructions host-neutral unless the user requires a specific host. Do
not install, publish, release, or change remote state unless the assignment
explicitly grants that authority.

## Verify and finish

Always validate the name, frontmatter, links, references, scripts, notices, and
subject metadata. Run each changed script with representative input. Test changed
behavior in proportion to its risk and reach. Include activation cases when the
description changes. Use an isolated boundary for side effects. Record the exact
reason when a behavioral check does not run. Static validation alone does not
prove behavior.

Confirm that the output meets the assignment acceptance criteria and the skill's
completion conditions. Fix in-scope package defects and repeat affected checks.
Report the selected route, taxonomy, changed files, evidence, untested behavior,
and any remaining decision. If a check cannot run, name the limit, recovery
attempted, and evidence still needed. Use Dojo only when the current request
explicitly names it. Do not call a mechanically conforming candidate adopted,
and do not report success when required evidence is missing.
