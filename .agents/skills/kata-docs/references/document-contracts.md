# Docs Kata document contracts

Use the project's existing documentation structure when it has clear rules.
Otherwise, use this structure under `docs/` and create a category only when it
has a document:

| Path | Contract |
| --- | --- |
| `README.md` | A short index of current documentation and fixed-path exceptions. |
| `inbox/` | A processing queue for new material. A clear queue contains only `README.md`. |
| `guides/` | Current instructions for completing a task. |
| `reference/` | Current behavior, interfaces, concepts, and configuration. |
| `decisions/` | Settled choices with context, reasons, and consequences. |
| `plans/` | Intended work, scope, acceptance conditions, and progress. |
| `lessons/` | Verified reusable findings and the conditions where they apply. |
| `archive/` | Historical, superseded, or unverifiable material retained for provenance, not current authority. |

The `docs/` tree is the project wiki. Do not add a separate `wiki/` category
unless project evidence shows a distinct consumer or publishing need.

Keep required root entry points, policies, licenses, changelogs, agent
instructions, published paths, and tool-owned files at their fixed locations.
Link them from the documentation index. If a project already uses another plan
root, preserve it and link it from `docs/README.md`; Docs Kata does not move
active plans only to enforce its default.

## Document identity

Each reviewed document needs a clear title, purpose, status, last-reviewed date,
and links to its evidence or related artifacts. Preserve an established project
format. Otherwise, use short YAML frontmatter:

```yaml
---
title: Durable agent activation
status: current
last-reviewed: 2026-11-04
---
```

Use a status that fits the document type:

- Inbox: `new`, `reviewing`, `placed`, or `blocked`.
- Plans: `draft`, `active`, `blocked`, `complete`, or `superseded`.
- Decisions: `proposed`, `accepted`, `rejected`, or `superseded`.
- Guides, reference, and lessons: `current`, `needs-review`, or `superseded`.
- Archive: `historical`, `superseded`, or `unverified`.

Do not rewrite a project with a different established status vocabulary only to
match these defaults. A status change needs evidence. Link a superseded document
to its replacement.

Use descriptive lowercase file names with hyphens. Use dates for documents
whose time is part of their identity, such as decisions and time-specific plans.
Do not rename a stable public path without preserving its consumers.
