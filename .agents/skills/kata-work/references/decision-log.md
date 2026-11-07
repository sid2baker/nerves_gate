# Keep an optional decision log

Use this method only when the assignment asks for a reviewable trail for
long-running or unattended work.

Copy [decision-log-template.tsv](decision-log-template.tsv) to `decisions.tsv`
or `.audit/<task>.tsv`. Keep it untracked by default. Track it only when the
assignment says that a reviewer needs the trail as part of the result.

Append one single-line TSV row for each material fork, completed unit, pivot,
revert, blocker, or gate correction. Do not log routine commands. Use these
columns:

- `ts`: ISO 8601 timestamp;
- `phase`: phase or workstream;
- `decision`: the choice or action;
- `why`: the plain reason;
- `evidence`: one resolving path, link, commit, line, trace, or image; and
- `result`: the observed state.

Prefix a cell that starts with `=`, `+`, `-`, or `@` with a single quote so a
spreadsheet does not run it as a formula. Keep the log append-only. Correct a
wrong row with a later row that supersedes it.

At handoff, compare this run's rows with the task history, diff, command output,
and artifacts. Confirm that each row maps to a real decision and that its
evidence supports it. Add missing pivots or corrections. Do not inspect
unrelated private records.

Report weak evidence, skipped checks, risky choices, and gaps. A decision log is
work evidence. It does not make the candidate verified.
