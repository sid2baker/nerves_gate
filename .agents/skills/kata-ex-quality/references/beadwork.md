# Optional Beadwork adapter

Read this file only when the operator explicitly selects Beadwork, `bw` is
available, and the target repository is already initialized.

The quality CSV files remain the source of truth for findings, rule versions,
evidence, and verification. Beadwork mirrors selected execution batches so a
long run can preserve work order and progress. Do not initialize Beadwork, copy
all backlog rows into it, or treat a closed task as quality verification.

1. Run the repository's normal Beadwork orientation command and inspect current
   work before changes.
2. Create one epic for the selected quality run only when no suitable active
   epic exists.
3. Create one child task per selected batch. Include the batch ID, backlog IDs,
   accepted scope, protections, and verification command in the task text.
4. Add dependencies only when the backlog `depends_on` relation requires them.
5. Start a task when its batch becomes in progress. Close it only after every row
   in the batch reaches verified. A fixed, blocked, restored, or split batch stays
   open or receives the matching project status.
6. Record the Beadwork task ID in evidence notes. Do not add a host-specific task
   ID column to the reusable backlog schema.

If Beadwork is unavailable, uninitialized, read-only, or conflicts with project
instructions, continue with CSV tracking and report that the mirror was skipped.
