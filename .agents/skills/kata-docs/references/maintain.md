# Maintain Docs Kata

Respect the requested scope. A request to check, audit, inspect, or report is
read-only. A request to tidy, clean up, conform, or maintain permits safe local
documentation repairs within the common authority envelope.

Check:

- every current inbox item, using `inbox.md` as a batch until only the intake
  log remains or each remaining item has a named blocker;
- local links, fragments, assets, and fixed-path consumers;
- index entries that have no target and current pages missing from the index;
- inbox items without provenance, status, or a clear next disposition;
- duplicate pages that claim to own the same subject;
- plans whose recorded status conflicts with direct completion evidence;
- decisions marked current after a linked replacement was accepted;
- reviewed pages with missing status, review date, or evidence;
- stale review dates and content that needs code-to-document reconciliation;
- empty category folders and placeholder pages.

Make only repairs that do not choose product intent: repair proven local paths,
remove duplicate index links, add a missing current page to the index, reconcile
an intake record with an existing move, apply a status change that direct
evidence proves, and correct selected documentation claims when current code or
tests prove the replacement. Preserve useful index text and established
document formats.

Do not use the inbox as an archive for material that is merely old, superseded,
or unverified. Move that material to `docs/archive/` with a non-authoritative
status and preserved provenance. Do not infer that a plan is complete from
elapsed time or a code change alone.
Do not select between conflicting documents, rewrite disputed content, archive
history, or delete a page without accountable direction. Report those items
with the evidence and the decision needed.

This route does not perform an unbounded claim-by-claim comparison with source
code. For a broad request, inventory the selected pages and their likely
authoritative sources before editing. Report any page whose correct content
needs a product decision.

Verify changed links, statuses, index entries, intake records, and the final
diff. Verify that `docs/inbox/` contains only `README.md`, or list each named
blocker with its owner and next action. Report both repaired items and remaining
content decisions.
