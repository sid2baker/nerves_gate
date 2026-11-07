---
name: kata-sitrep
description: Give a decision-ready local and remote Git workbench report. Use for one repository or a folder of active projects before new work or cleanup; use an application-health skill for service status.
metadata:
  schema: kata.skill/v1
  subject: software-engineering
  practice: report
  object: git-workbench
  profile: bounded-execution
  authority: local-write
  consumes: "git-repository, project-folder"
  produces: "git-workbench-report"
---

# Kata Sitrep

**Outcome:** The operator or calling skill receives the smallest Git workbench
report that identifies work needing a decision.

**Done:** Every in-scope repository has local, sync, and relevant open-work
status or an explicit unknown, and the report names the most useful next action.

**Authority:** Inspect the requested Git roots and provider state. One fetch
without pruning is a permitted local write to remote-tracking refs. Do not
change files, local branches, worktrees, issues, pull requests, or other remote
items.

**Work profile:** Use `bounded-execution` for one repository. Use `coordination`
for a folder of projects because the report integrates several bounded checks.

Use judgment to show only the facts the operator needs to choose the next action.

## Find the active roots

Resolve the requested repository or project folder. Ask only when several
plausible roots would materially change the report. Start with local Git commands:

- Use `git rev-parse --show-toplevel` to find the current root.
- Use `git worktree list --porcelain` to find its linked worktrees.
- If the target is a folder of projects, use its workspace configuration when
  available. Otherwise, check its direct child directories with
  `git -C <path> rev-parse --show-toplevel`.

Inspect each Git root once. Do not search all nested directories. Exclude
repositories stored as dependencies, fixtures, generated output, or references
unless the user includes them.

## Check what needs a decision

Use `git status --short --branch`, `git worktree list`, and `git branch -vv` as
the core local checks. For each active repository, find:

- dirty or unfinished worktrees;
- current branch sync with its upstream;
- local branches that are unmerged, unpushed, or have no valid upstream.

Fetch the primary remote once when available. Check the Git provider only for
open pull requests authored by the current user, review requests for that user,
pull requests for local branches, and issues assigned to that user. Do not count
all upstream issues, pull requests, or remote branches. If access is unavailable,
mark remote status as unknown and continue with the remaining checks. Do not
repeat the same check unchanged. Report the evidence limit. Do not repair the
repositories.

Do not run tests, builds, or history analysis.

## Show the result

Skip the preamble. If everything is clean, use one sentence. Use a table only
when two or more projects or worktrees need comparison:

`Project | Local | Sync | Open work`

Use one row per project. Group its worktrees in that row. Do not add a row for
each clean worktree. Keep local cleanliness separate from remote work.

Aim for this scale:

```text
Workbench needs attention.

| Project | Local | Sync | Open work |
| --- | --- | --- | --- |
| api | 1 dirty worktree | behind 2 | 1 unpushed branch |

- feature worktree: 3 untracked files

Next: review the untracked files.
```

After the table, use at most three short bullets for dirty paths, branches that
need a decision, or relevant remote items. Include links for remote items. End
with one `Next:` line that names the most useful cleanup action. Do not perform
that action unless the user requests it.
