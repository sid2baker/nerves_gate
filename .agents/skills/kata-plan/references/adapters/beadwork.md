# Beadwork Plan Adapter

Run this adapter only when the user explicitly requests `beadwork` or asks to
materialize the plan as a Beadwork issue graph. A valid Markdown plan remains
the primary result when this adapter is unavailable or fails.

## Preconditions

Require:

- a repository-backed canonical Markdown plan;
- `artifact_readiness: implementation-ready`;
- stable implementation unit IDs and an acyclic dependency graph;
- an installed `bw` command; and
- an already initialized, readable Beadwork repository.

Check availability without changing state:

```sh
command -v bw
bw -C <git-root> list --all --json
```

If either check fails, record the adapter failure in Markdown and stop this
adapter. Do not run `bw init`, repair Beadwork, change its configuration, or
substitute another tracker.

## Avoid duplicate graphs

Read the Markdown Adapter Results and current Beadwork issues before creating
anything. Reuse a recorded epic and tasks when they still exist and match the
plan. Search existing issue descriptions for the canonical plan path when IDs
are absent.

If an existing graph conflicts with the plan, report the conflict. Do not
delete, close, replace, or silently duplicate existing issues.

## Map the plan

Create:

- one epic for the software outcome; and
- one task for each implementation unit.

The epic description includes:

- canonical plan path;
- objective and scope;
- key technical direction;
- Definition of Done; and
- the initial frontier.

Each task description includes:

- stable unit ID and outcome;
- requirements and key technical decisions;
- grounded affected surfaces;
- implementation direction and invariants;
- acceptance and test scenarios;
- verification commands or checks;
- completion signal; and
- canonical plan path and heading anchor.

Keep the Markdown plan authoritative. Do not copy general project background
that an executor does not need for the unit.

## Create and wire the graph

Create the epic first. Create tasks in dependency order so real IDs are
available for later descriptions and edges. Use the current supported Beadwork
interface:

```sh
bw -C <git-root> create "<epic title>" --type epic --description "<body>" --silent
bw -C <git-root> create "<task title>" --type task --parent <epic-id> --description "<body>" --silent
bw -C <git-root> dep add <blocker-id> blocks <blocked-id>
```

Use one edge for each canonical unit dependency. Do not add ordering edges that
the plan does not declare.

If a create or edge operation fails, stop further writes. Preserve and report
every returned ID. Do not delete partial results.

## Verify the graph

Read created state back:

```sh
bw -C <git-root> show <epic-id> --json
bw -C <git-root> list --parent <epic-id> --json
bw -C <git-root> ready --json
```

Also read each created task when the list output does not include its complete
description and dependencies.

Confirm:

- one epic points to the canonical plan;
- every implementation unit maps to exactly one task;
- task titles and descriptions carry the correct unit ID;
- every planned blocking edge exists with the correct direction;
- no extra edge changes the initial frontier;
- initial ready tasks match the plan; and
- task acceptance and verification match the canonical unit.

## Update the canonical plan

After verification, update Markdown Adapter Results with the epic ID, task
count, and unit-to-task mapping. Do not put issue status or assignee into the
plan.

If HTML was requested, render it after this update. If Markdown changed but
HTML cannot be regenerated, mark the HTML adapter as failed so consumers do not
use a stale view.

Report the epic ID, task IDs, initial ready tasks, and any partial or failed
operation. Beadwork success does not start implementation.
