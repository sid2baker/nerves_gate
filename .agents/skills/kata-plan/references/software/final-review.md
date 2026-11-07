# Review the Software Plan

Review the plan as an execution contract. Fix safe defects in wording,
structure, IDs, links, and internal consistency. Do not use review to make an
unowned product or risk decision.

## Product preservation

When a Product Contract exists, compare the final plan with it and confirm:

- the objective and beneficiary are unchanged;
- requirements and acceptance examples keep their meaning;
- scope and non-goals are preserved;
- settled decisions were not reopened or weakened;
- every in-scope requirement has technical and verification coverage; and
- new technical constraints do not silently reduce product behavior.

Record one preservation note:

- `Product Contract unchanged`;
- `Product Contract restructured without scope change: <mapping>`; or
- `Product Contract changed with owner approval: <requirements and reason>`.

A substantive product change without approval makes the plan
`planning-blocked`.

## Technical completeness

Confirm that the plan explains:

- relevant current behavior and evidence;
- target behavior and system ownership;
- the selected approach and load-bearing decisions;
- affected interfaces, data, lifecycle, and external systems;
- compatibility, migration, rollout, and recovery when triggered;
- coherent implementation units and real blocking edges;
- exact test scenarios and supported verification gates; and
- the final observable Definition of Done.

Remove sections that contain only generic advice. Add a missing conditional
section only when evidence shows that its risk is present.

## Execution usability

Read the plan from the next executor's position. Confirm that the executor can:

- start with the Goal Capsule and current frontier;
- read one unit and its cited requirements and decisions;
- find grounded files, modules, interfaces, and tests;
- distinguish required structure from implementation freedom;
- know when the unit is complete;
- run or confirm the named verification; and
- identify the owner of each unresolved decision.

Do not require the executor to reconstruct research, infer dependency order, or
search for the acceptance contract.

## Mechanical checks

For a saved Markdown artifact, check:

- valid YAML frontmatter;
- `artifact_contract: kata-plan/v1`;
- accurate `artifact_readiness`;
- unique and stable R, KTD, and U identifiers;
- no broken relative links;
- no unresolved placeholder text;
- no dependency on an unknown unit;
- no circular unit dependency;
- valid requirement-to-unit-to-verification coverage;
- sources that support every consequential external fact; and
- a clean scoped diff with no unrelated file change.

If the plan enriches an existing artifact, inspect the diff for lost product
content. If a new file was selected, confirm that it did not overwrite an
existing path.

## Readiness result

Use `artifact_readiness: implementation-ready` only when:

- product behavior, scope, and acceptance are settled;
- every material technical decision is resolved or safely delegated to the
  executor;
- the work graph is acyclic and actionable;
- verification is sufficient for each requirement and risk; and
- no missing fact can change architecture, data safety, public contracts, or
  the first executable unit.

Repair in-scope plan defects and repeat affected checks before setting
readiness.

Otherwise use `artifact_readiness: planning-blocked`. List each blocker, owner,
affected sections, and the next action that can resolve it. A detailed blocked
plan is useful, but it is not implementation-ready.

When the local plan file passes these checks, the package can report
`verified-change` for that plan artifact. This means the local planning change
is mechanically and semantically checked. It does not mean that the future
software implementation is verified or accepted.

## Adapter review

After optional adapters run:

- confirm each Beadwork ID maps to one stable unit or the plan epic;
- confirm every Beadwork edge matches the canonical unit graph;
- confirm HTML identifies and links to the canonical Markdown source;
- confirm HTML content reflects the final Markdown after Beadwork updates; and
- report an adapter failure separately from the Markdown plan readiness.
