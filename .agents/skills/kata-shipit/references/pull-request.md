# Push and create or update a pull request

Use this method only when the current request grants remote-write authority.
A bare Ship It invocation grants normal push and PR authority for the accepted
change. Keep any explicit limit in the request.

## Resolve state

1. Identify the repository, remote, current owner, head branch, base branch,
   current `HEAD`, upstream, and remote default branch.
2. For PR delivery, if the head is detached or is the default branch with work
   to publish, create a feature branch. Carry accepted local commits from this
   task. Preserve current work. Do not stash, reset, or clean. For a requested
   direct push, use the named target if repository rules permit it; confirm a
   fast-forward with only accepted commits.
3. Query for an existing open pull request for the exact head owner and branch.
   Empty successful output means none exists. A failed query means unknown.
4. Re-check repository, branch, `HEAD`, and remote immediately before pushing.
5. Push the live `HEAD` normally. Never force push without exact authority.
6. For a requested direct push, verify the remote target has the intended
   commit and report the result. Stop here; no PR is needed.

## Compose the pull request

Use the repository template and conventions. The title states the delivered
outcome. The body contains only useful sections:

- **Summary:** What changes for the user or system.
- **Why:** The problem or requirement that caused the change.
- **Changes:** The main implementation units, not a file list.
- **Verification:** Exact checks and observed results for this commit state.
- **Risks or follow-up:** Known limits, rollout needs, or omitted work.
- **Related:** Existing issue or plan links that the source supplied.

Do not claim a test or review that did not run. Preserve valid issue-closing
links and important text when updating an existing body.

For GitHub, prefer `gh`. Pass the body through a temporary file so shell
characters cannot change it and an empty body cannot be accepted silently.
Remove the temporary file after use.

Immediately before pull request creation, query again for an existing matching
pull request. Update the existing pull request only when the request permits an
update. Otherwise report it and stop. After create or update, read the pull
request back and verify its URL, head, base, title, and body.
