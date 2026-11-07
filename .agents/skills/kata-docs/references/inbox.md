# Process Docs Kata inbox material

Process one item by default for a targeted inbox request. Select a named item
first. Without a named item, use the oldest `new` item whose source and required
evidence are available. When maintenance invokes this route, process every
current item until only `README.md` remains or each remaining item has a named
blocker.

1. Read the item, its intake record, provenance, related assets, and links.
   Identify the reader question or task it can support.
2. Check material claims against current code, tests, configuration, accepted
   decisions, or other authoritative project sources. Separate observed facts,
   intended behavior, settled decisions, and unresolved questions.
3. Select the category by its document contract. Prefer updating an existing
   page when it already owns the subject. Split or combine material only when
   that improves its use and preserves relevant information.
4. Give a reviewed document a title, purpose, supported status, last-reviewed
   date, evidence links, and related document links. Preserve the project's
   established format.
5. Move the item and its assets to a collision-free destination. Repair affected
   links and consumers. Update the index and intake log with the destination,
   review result, and date.
6. If material is historical, superseded, contradictory, or cannot be verified,
   preserve it under `docs/archive/` with its provenance, review date, status,
   and a clear warning that it is not current authority. Repair consumers and
   record the destination. Do not invent facts or delete history.
7. Leave an item in the inbox as `blocked` only when a required decision,
   permission, fixed-path consumer, or missing evidence prevents both normal
   placement and safe archival. Record the blocker, owner, and next action.

Verify the destination content, assets, links, index, intake record, and diff.
Report the evidence used and each claim that remains unverified. For a batch,
also verify that `docs/inbox/` contains only `README.md`; otherwise report every
remaining blocker and do not report maintenance as complete.
