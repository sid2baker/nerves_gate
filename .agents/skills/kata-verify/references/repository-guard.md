# Repository guard verification

Use this method when a candidate claims to prevent a repeated repository
mistake. The work owner supplies the candidate guard and work evidence.
Verification stays read-only and does not repair the guard.

## Required proof

Verify all of these conditions:

1. Evidence identifies at least two distinct occurrences of one mistake class.
2. The guard rejects one real past bad case at the intended boundary.
3. The same guard accepts the corrected state.
4. The candidate and the proof do not absorb, overwrite, or claim unrelated
   repository changes.

Use a commit, revert, review record, or other durable repository evidence to
identify the past bad case. Reconstruct it in a temporary isolated copy or an
equivalent fixture. Do not change the target candidate. If the real case cannot
be reconstructed safely, return **Unknown** for that condition.

## Check the candidate

1. Record the exact candidate identity and the repository state that existed
   before the check. Separate pre-existing changes from candidate changes.
2. Run the guard against the real past bad case. Record the command, exit
   status, and diagnostic. A rejection passes only when it identifies the
   intended mistake and points to the supported state or path.
3. Run the same guard against the corrected state. It must accept that state.
4. Inspect the candidate diff and the repository state after the proof. Confirm
   that unrelated files and changes remain separate and unchanged. When a
   broad false positive is a material risk, also run one representative valid,
   unrelated change through the guard.
5. Remove temporary proof material. Report any material that cannot be removed
   as a failure or blocker, as applicable.

Return **Fail** when the guard misses the past bad case, rejects the corrected
state, includes unrelated work, or changes unrelated target state. Return
**Unknown** when a required real case or corrected state cannot be reproduced.
Report the direct evidence and return all defects to `kata-work`.
