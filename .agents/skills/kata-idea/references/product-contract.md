# Product Contract

Write a durable Product Contract only when the user asks for one or a later
roadmap, planner, or reviewer needs stable decisions. `kata-roadmap` can resolve
a long-horizon decision route from the contract. `kata-plan` can enrich a
contract whose route is already clear. Otherwise return the idea brief in chat.

Use the repository's configured documentation root when one exists. Otherwise
use `docs/`. Write under `docs/plans/` with this shape:

```text
YYYY-MM-DD-HHMM-idea-<topic>-plan.md
```

Do not overwrite an existing file. Add the smallest numeric suffix when the
path already exists.

Use this frontmatter so `kata-plan` can enrich the artifact:

```yaml
---
artifact_contract: kata-plan/v1
artifact_readiness: requirements-only
product_contract_source: kata-idea
title: <short outcome title>
---
```

The body must contain:

```markdown
# <Title>

## Goal Capsule

- Objective:
- Means:
- Authority:
- Stop conditions:

## Product Contract

### Summary

### Problem Frame

### Actors

### Requirements

- R1. ...

### Key Flows

### Acceptance Examples

### Success Criteria

### Scope Boundaries

- In:
- Out:

### Key Decisions

### Rejected Alternatives

### Dependencies

### Outstanding Questions

### Sources
```

Keep requirements about product behavior. Do not add file paths, database
columns, libraries, class names, or implementation units unless the idea itself
is a technical-interface decision. Cite repository facts with paths and line
numbers when they affected a decision.

Before handoff, check:

- **Complete:** A planner does not need to invent user behavior, scope, or
  success criteria.
- **Consistent:** Requirements, decisions, and scope do not conflict.
- **Focused:** The artifact owns one coherent outcome.
- **Usable:** Each open question is visible and each settled requirement has a
  stable identifier.

Fix wording and structure directly. Ask before changing a product decision.
