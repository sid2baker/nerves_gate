# Create scoped local commits

Use this method only after the accepted change and current verification are
known.

1. Inspect the full staged and unstaged state. Do not include ignored files.
2. Compare the accepted paths with existing staged work. Stop when the index
   cannot be separated safely.
3. Group files into separate commits only when they are independent logical
   changes. Use one commit when the boundary is not clear. Do not use partial
   hunk staging to manufacture a boundary.
4. Stage explicit paths. Never use a broad add command unless the operator
   selected the complete worktree and every file was reviewed.
5. Inspect the complete staged name list, diff, and diff stat. Run the
   repository's whitespace or diff check.
6. Confirm that no credential, token, private key, personal data, or unrelated
   generated file is staged. Report a suspected secret without reproducing it.
7. Write a concise imperative message that matches repository conventions.
8. Commit only the named paths. Do not absorb unrelated paths that were already
   staged.
9. If a hook fails or changes files, pause the commit and inspect the new state.
   Return any required repair to its work owner. Resume only after the repair
   is complete and verification applies to the current staged state. Do not
   bypass the hook or retry an unchanged failure.
10. Verify each new hash, subject, changed path list, and the remaining worktree
    state.

Preserve authorship when the commit includes another person's ported work. Use
recorded co-author information. Never guess an identity or email address.
