# Markdown Plan Adapter

Markdown is the canonical representation of every saved software plan. Other
adapters derive from it.

## Select the path

For an existing Markdown Product Contract or implementation plan, update that
file in place after confirming that it is the requested artifact.

For a new repository plan, use the repository's documented plan directory. If
none exists, use `docs/plans/`. Use this filename shape in the user's local
time:

```text
YYYY-MM-DD-HHMM-<topic>-plan.md
```

Use a short lowercase topic slug. Create the file without overwriting an
existing path. On collision, add the smallest positive numeric suffix before
`.md`.

For chat-only output, use the same section contract without frontmatter or an
artifact path. A chat plan does not produce `verified-change`.

## Frontmatter

Use:

```yaml
---
title: <short outcome title>
type: implementation-plan
date: YYYY-MM-DD
last_reviewed: YYYY-MM-DD
artifact_contract: kata-plan/v1
artifact_readiness: implementation-ready | planning-blocked
domain: software
execution: code
product_contract_source: kata-idea | direct-request | <other explicit source>
---
```

Preserve useful existing metadata that does not conflict with this contract.
Remove stale fields that claim a different readiness or source. Do not add
progress, assignee, branch, or completion percentage fields.

## Required body

Use this order. Keep every required section. Add conditional subsections only
when the design triggers them.

```markdown
# <Title>

## Goal Capsule

- Objective:
- Means:
- Authority:
- Stop conditions:
- Next executor:

## Product Contract

### Summary
### Problem Frame
### Actors
### Requirements
### Key Flows
### Acceptance Examples
### Success Criteria
### Scope Boundaries
### Key Decisions
### Rejected Alternatives
### Dependencies
### Outstanding Questions
### Sources

## Planning Contract

### Product Contract Preservation
### Current System
### Target System
### Key Technical Decisions
### System Boundaries and Change Surface
### Implementation Units
### Work Graph
### Verification Contract
### Rollout and Recovery
### Risks and Assumptions
### Open Planning Decisions
### Definition of Done
### Planning Sources

## Adapter Results
```

When no upstream Product Contract exists, the Product Contract section records
only settled facts from the direct request and repository evidence. Assign R
identifiers to in-scope requirements so the planning and verification sections
can trace them. Do not invent an actor, flow, or success measure. Use `None
identified` only when evidence shows that a subsection does not apply. A
missing product decision belongs under Outstanding Questions and can block
readiness.

## Section rules

### Goal Capsule

Keep it short enough to orient a fresh executor. The Objective states the
observable outcome. Means states the selected technical direction, not a list
of files. Authority and Stop conditions preserve execution limits. Next
executor names the expected role, not a person unless the user named one.

### Product Contract

Preserve upstream requirement IDs and settled text. Do not duplicate product
requirements in technical prose. Cite them from KTD and U entries.

### Current and Target System

Describe ownership and behavior. Use grounded file and symbol anchors. A small
flow or state diagram is useful when sequence or lifecycle is material. Do not
paste a repository inventory.

### Key Technical Decisions

Use `KTD1`, `KTD2`, and so on. Each decision states the choice, reason,
consequences, rejected alternative when material, and governed requirements or
units.

### System Boundaries and Change Surface

Use a table when several boundaries change:

| Surface | Current contract | Planned change | Compatibility or risk |
| --- | --- | --- | --- |

List exact files only when current evidence supports them. Explain why each
path or interface is in scope.

### Implementation Units

Use one subsection per stable U ID. Follow the complete unit contract from
`software/work-units.md`. Put dependencies near the unit title.

### Work Graph

List the initial frontier, parallel groups, critical path, and final integration
unit. Add a Mermaid diagram when it is materially clearer than the list. Keep
the text form authoritative for agents and adapters.

### Verification Contract

Use a gate table plus requirement traceability. Exact commands use fenced code
blocks and state their working directory. Do not include secret values.

### Rollout and Recovery

Include this section for deployment, migration, external integration, or risky
activation. Otherwise state the integration boundary and why no special
rollout is needed in one short paragraph.

### Risks, assumptions, and open decisions

Separate supported risk from assumption. Mark each open decision as blocking
or deferred, name its owner, and state which unit it controls.

### Adapter Results

Keep the section even when no optional adapter ran. Use:

```markdown
- Markdown: canonical at `<path>`
- HTML: not requested | `<path>` | failed: <reason>
- Beadwork: not requested | epic `<id>`, tasks `<count>` | failed: <reason>
```

## Markdown quality

- Use prose for rationale and bullets for contracts or checks.
- Use tables only for repeated fields or comparisons.
- Keep headings stable and descriptive.
- Use relative repository links when they will remain valid from the plan path.
- Add line numbers only for evidence whose exact location matters and is not
  likely to move immediately.
- Keep code examples directional and short.
- Do not include the planning conversation, discarded research, confidence
  scores, model names, or tool transcripts.
