# Reconstruct recent work context

Use this mode for a bounded recall topic or activity range.

1. Resolve the topic, workspace, time range, and available sources. Default
   "recent" to seven days. Never search another workspace without the user's
   request.
2. Use a complete supplied state capsule when it already identifies paths,
   branch, change, decisions, and open work. Do not mine history again.
3. Search the available chat history by real modification time. Read only
   matching regions. Skip the current chat, delegated-worker noise, evaluations,
   and tests unless they contain the requested work.
4. For a named feature, subsystem, or bug, also check available repository,
   issue, team, document, and error records. Look for current symptoms, attempts
   that failed or were reverted, and open work. An unavailable source is an
   explicit limit.
5. Verify branches, pull requests, tickets, and worktree state against current
   `git` and provider evidence. Read the full transcript when the answer depends
   on the exact actions an agent took.

Return:

- a capsule of at most five bullets;
- one line per thread with its supported state, such as merged, open, in flight,
  verified but uncommitted, reverted, or planned;
- at most five recurring problems; and
- one concrete next move.

Stay on the named topic. Cite stable chat or record identifiers when they exist.
Remove private context from any public output. Do not start or resume the work.
