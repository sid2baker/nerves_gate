# CSV Roadmap Backend

Use one CSV file as the complete roadmap state when Beadwork is unavailable
and only one writer can change the roadmap. CSV is portable storage. It is not
a safe concurrent claim system.

## Path and schema

Use the path supplied by the user. Otherwise use:

```text
docs/roadmaps/<topic>.csv
```

Create parent directories only inside the target repository. Do not overwrite
an unrelated file. Use this exact header:

```csv
schema,roadmap_id,item_id,record_type,title,destination,acceptance,question,kind,interaction,status,blocked_by,owner,target_by,review_by,authority,expected_evidence,resolution,evidence_refs,notes,revision,updated_at
```

Use `kata-roadmap/v1` in `schema`. Follow RFC 4180 CSV quoting. Use a CSV parser
that preserves quoted commas, quotes, and newlines. Do not split rows with a
plain string operation.

## Record types

Keep exactly one `roadmap` row. It carries the destination, acceptance,
accountable owner, target, review point, authority, status, and low-resolution
notes. Its `item_id` is the stable Roadmap ID.

Use these other row types:

- `decision`: One sharp question. Use stable `D<n>` item IDs.
- `fog`: One coarse in-scope territory that is not yet a precise question. Use
  stable `F<n>` item IDs and leave `question` and `blocked_by` empty.
- `out_of_scope`: One excluded item and its reason. Use stable `O<n>` item IDs.

For `blocked_by`, join stable decision IDs with semicolons. Do not put backend
paths or row numbers in dependency fields.

Use `open`, `in_progress`, `resolved`, or `out_of_scope` for decision status.
Use `active`, `complete`, or `blocked` for the roadmap row. Do not save
`blocked` as a decision status.

Use an integer `revision` for each row and increment it on every update. Use an
RFC 3339 timestamp in `updated_at`. Keep unknown evidence in `notes`; do not
invent an answer to fill a cell.

## Single-writer rule

Before every write, read and validate the complete file again. Stop when:

- another decision is `in_progress` under a different owner;
- a row revision changed after the current run selected it;
- duplicate stable IDs exist;
- the schema is unknown; or
- another writer can operate concurrently.

Use Beadwork for parallel work. Do not add a lock-file protocol that the skill
cannot enforce across hosts.

## Create and update

For creation, write the roadmap row first in memory, add decision and fog rows,
validate the full graph, then create the file once. Do not expose a partially
written CSV as a successful roadmap.

For an advance:

1. Read and validate the file.
2. Select one open frontier decision.
3. Set that row to `in_progress`, record its owner, increment its revision, and
   write and read the file back.
4. Perform the decision work.
5. Read and validate the file again.
6. Write the resolution and evidence, set `resolved`, increment the revision,
   reconcile fog and scope rows, and update the roadmap row.
7. Read and validate the final file.

When a human answer is unavailable, restore the selected row to `open` unless
the same operator will resume from this exact file and the saved claim is the
desired coordination state.

## Verify

After every write, confirm:

- the file parses with the exact header and schema;
- one roadmap row exists;
- `roadmap_id` is the same on every row;
- `item_id` values are unique;
- every blocker names an existing decision;
- the decision graph is acyclic;
- every resolved decision has a resolution and evidence reference;
- every active decision has one owner;
- fog rows contain no precise decision dependency;
- the calculated frontier matches the reported frontier; and
- a complete roadmap has no open, active, fog, or blocked item.

Report the absolute CSV path and a content hash when the available tools can
calculate one. A parsed and internally consistent CSV is a verified backend
result; it does not prove that each decision is correct.
