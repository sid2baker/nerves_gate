# Watch or land a pull request

## Watch

Use the host's supported pull request wait or monitor capability when available.
Otherwise use the forge CLI with a bounded wait. Observe:

- required check states;
- mergeability;
- draft state;
- required approvals and blocking review requests;
- new review comments that require an accountable decision; and
- whether the head commit changed since verification.

Do not report unchanged state unless the user asked for periodic updates. For
observation-only work, stop when checks pass, a failure needs repair, a review
needs a decision, the head changes, or the requested bound is reached. A changed
head invalidates evidence that named the old commit.

If authorized follow-through includes repair, pause observation, send the failed
condition to its work owner, verify the repaired head, and resume the selected
delivery route. Keep the original delivery target and resource limit.

## Land

Land only under explicit merge authority.

1. Re-read the pull request URL, repository, head commit, base, draft state,
   checks, reviews, and mergeability.
2. Stop when required checks fail or are pending, approval is missing, a
   blocking review is unresolved, the head changed, or the target is ambiguous.
3. Resolve the merge strategy from the request and repository rules. Ask when
   squash, merge commit, or rebase would preserve materially different history.
4. Use the forge's normal merge operation. Do not bypass protections or enable
   an automatic merge unless the request grants that action.
5. Read the pull request and base branch state after the operation. Record the
   merge commit or equivalent final identity.

Do not delete the remote branch, local branch, or worktree as an implied cleanup
step. Those actions need separate explicit authority.
