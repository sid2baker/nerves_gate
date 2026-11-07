# Repository guard method

Use this method only when the requester explicitly asks to prevent a repeated
repository mistake and evidence identifies at least two occurrences. A single
defect is normal work. If the repeated evidence is not established, return the
request to understanding.

## Outcome

Produce one candidate repository guard and direct work evidence. Keep
`kata-work` as the change owner. Do not certify the guard. Independent
verification owns the verdict.

Design for a contributor who sees only the files that they opened, copies the
nearest example, and takes the shortest path that compiles. A change that looks
correct from one file must also be correct for the repository.

## Select the strongest guard

Use the first level that can make the mistake impossible or make it fail at a
useful boundary:

1. Eliminate the bad state through architecture. Give state one owner, provide
   one supported path, hide an unsafe internal path, or replace copied lists
   with one source of truth.
2. Use types or compile-time constraints so the bad state cannot be written.
3. Add a lint rule or executable check with an error that names the problem and
   the supported path.
4. Add a behavior test that fails when the mistake changes observable behavior.
5. Use documentation only for judgment that cannot be enforced.

Do not add lower-level controls when a higher-level control is sufficient. If a
pattern is already common, make the guard reject new occurrences without
requiring an unrelated cleanup. Keep an exception beside the guarded case and
require a reason, an expiry condition, and an accountable owner.

## Build one candidate

1. Name one mistake class and cite two distinct occurrences from commits,
   reverts, review comments, or current repository evidence.
2. State the selected enforcement level and why each higher level cannot solve
   the class in the current scope.
3. Make the smallest coherent change. Preserve pre-existing and unrelated
   work. Do not absorb a second mistake class.
4. Run focused local checks when they are safe. When possible, record how the
   candidate reacts to one real past bad case and to the corrected state. Treat
   these results as work evidence, not as a verification verdict. Use the same
   command as continuous integration when it is available locally.
5. Inspect the final diff and repository state. Confirm that the candidate
   guard and its evidence are identifiable and that unrelated changes remain
   separate.

If the repository has a rule table, update only the row for this mistake and
pair it with the enforcement. Remove the row when the mistake becomes
impossible. Do not create a table when the guard already makes the rule clear.

Report the mistake class, the two occurrences, the selected enforcement level,
the candidate identity, the local checks, and all limits. Hand the candidate to
independent repository-guard verification.
