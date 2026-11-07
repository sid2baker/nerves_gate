# Quality data contract

Read this file before a run creates or changes quality data.

## Files and tool

The default project files are:

- `docs/quality/backlog.csv` for finding identity and state;
- `docs/quality/evidence.csv` for revision-specific detection and verification;
  and
- `docs/quality/rules.csv` for project rules and built-in applicability records.

Use [the bundled tool](../scripts/quality_backlog.exs) from the target project:

```text
elixir <skill-directory>/scripts/quality_backlog.exs <command> [options]
```

Run `help` for commands and options. Use `init` to create missing files and
`check` before reading or changing managed state. The tool is the only supported
writer for existing rows. It rejects field line breaks, invalid CSV, unknown
values, duplicate IDs, bad transitions, missing dependencies, and invalid
verification evidence.

Use one writer at a time. If another actor changes a file during a run, stop,
reload, and reconcile before the next write.

## Backlog state

The version 1 header is copied from
[the backlog template](../assets/quality-backlog.csv):

```text
schema_version,id,rule_id,rule_version,status,class,priority,confidence,scope,location,summary,owner,depends_on,batch_id,latest_evidence_id,first_seen,last_seen,closed_on
```

IDs use `EXQ-NNNN` and are never reused. Rule versions are positive integers.
Statuses are `open`, `selected`, `in_progress`, `fixed`, `verified`, `deferred`,
`invalid`, and `blocked`. Classes are `objective-fix`, `safe-refinement`,
`backpressure-gap`, and `judgment-required`. Priorities are `p0` through `p3`.
Confidence is `confirmed`, `supported`, or `candidate`.

`scope` and `location` identify the affected project boundary. `depends_on` is a
semicolon-separated list of backlog IDs. `batch_id` uses
`EXQ-B-YYYYMMDD-NN`. `latest_evidence_id` points to the newest direct evidence.
Dates use `YYYY-MM-DD`. `closed_on` is set only for verified or invalid rows.

Normal progress is:

```text
open -> selected -> in_progress -> fixed -> verified
```

An in-progress row can move directly to verified when all proof runs in the same
batch. Reopen a verified or invalid row when new evidence supports it. Return a
selected, in-progress, or fixed row to open when its batch is restored. A
verified transition requires passing evidence for that finding.

## Evidence

The version 1 header is copied from
[the evidence template](../assets/quality-evidence.csv):

```text
schema_version,evidence_id,finding_id,source_revision,observed_on,command,measure,before_value,after_value,unit,result,artifact,notes
```

Evidence IDs use `EXQ-E-NNNN`. `source_revision` is a full Git revision for a
clean tree. For a dirty tree, append a fingerprint of the relevant tracked and
untracked content, not only a generic dirty marker. Outside Git, use another
stable source identity.
`result` is `fail`, `pass`, `blocked`, or `not_run`. Before evidence normally
has a failing result and can leave `after_value` empty. Verification evidence
has a passing result and both values when the rule measures a numeric change.

Use `artifact` for a repository-relative report, log, or waiver record. Keep
commands and notes concise. Do not store secrets, large raw output, or line
breaks in CSV fields.

## Project rule registry

The version 1 header is copied from
[the rule template](../assets/quality-rules.csv):

```text
schema_version,rule_id,rule_version,status,surface,cost,requires,default_class,auto_fix,playbook,owner,reason
```

Statuses are `enabled`, `disabled`, and `not_applicable`. Surfaces are `gates`,
`proof`, `tests`, `code`, and `architecture`. Costs are `cheap`, `normal`, and
`expensive`. `auto_fix` is `yes` or `no`.

A new project rule uses a project prefix and a repository-relative playbook. A
row with a built-in ID can only set applicability. It cannot change the built-in
version, surface, class, or playbook. Disabling or excluding an advisory rule
requires an owner and reason. A configured required gate cannot be disabled.

## Identity and history

Treat `rule_id + rule_version + scope + location + normalized root cause` as the
finding key. Several messages can support one finding. Distinct behavior
boundaries can have separate rows when they need independent fixes.

Keep closed rows and evidence. If a rule changes materially, increment its
version. Recheck older open rows before selection. Do not rewrite old evidence
to match a new rule.

The tool accepts historical built-in versions so old backlog rows remain
readable. It accepts only the current version for a new row or selection. When
an old open row still applies, preserve its evidence, close it with the truthful
result, and add a current-version row from new evidence. Do not relabel old
evidence with the new version.

## Execution guidance

Version 1 does not store model names or reasoning profiles in backlog columns.
Derive the default confirmation and application profiles from the built-in rule
index or the project rule's `requires` value. Record an instance-specific
elevation and its cause in evidence notes and the run report. Do not lower a
rule's profile through a project applicability row.

Keep this guidance portable. A project rule can use `reasoning:low`,
`reasoning:medium`, or `reasoning:high` in its semicolon-separated `requires`
value when confirmation and application use one profile. Use separate
`confirm:PROFILE` and `apply:PROFILE` entries when they differ. A profile does
not grant write, model-selection, delegation, or external-system authority.
