# Repository Issue Storage

Use one repository document as the issue-storage contract:

```text
docs/agents/issues.md
```

The document selects one issue backend for the repository. All skills that
create or update issues must use the same selection. Do not infer a second
backend from an installed CLI, Git remote, or existing data.

Use this shape:

```markdown
# Issue storage

- Backend: beadwork | csv | github | jira
- Location: <repository-relative path, owner/repo, or Jira project>
- CLI: bw | none | gh | twg
- Authority: local | remote
- Guidance: <commands, relationship rules, labels or types, and any limits>
- Last checked: YYYY-MM-DD
```

The guidance must be clear enough to create, read, relate, claim, resolve, and
list ready issues without guessing. Keep credentials and access-bearing URLs
out of the document.

## Backend gates

- **Beadwork:** Require `bw` and an already initialized repository. Never
  initialize, upgrade, repair, or synchronize it without separate authority.
- **CSV:** Require a repository-relative CSV path and one active writer. CSV
  uses no issue CLI.
- **GitHub Issues:** Use only the `gh` CLI. Require `command -v gh`, a confirmed
  `OWNER/REPO`, successful read access, explicit remote-write authority, and
  guidance for parent links and blockers. Do not use a connector or direct HTTP
  client as a substitute.
- **Jira Issues:** Use only the `twg` CLI. Require `command -v twg`, explicit
  remote-write authority, and repository guidance that names the Jira site or
  workspace, project, issue types, and tested commands. Do not guess `twg`
  syntax or use another Jira client.

If the selected CLI is absent, access fails, or guidance is incomplete, do not
use that backend. Report the missing condition. Do not silently fall back to a
different issue store.

## Current roadmap support

`kata-roadmap` currently implements Beadwork and CSV. GitHub and Jira support
must use the same repository contract after their queued adapters are written
and checked. A repository that selects GitHub or Jira cannot use the current
roadmap package for issue writes; report the queued adapter instead of creating
local duplicate issues.
