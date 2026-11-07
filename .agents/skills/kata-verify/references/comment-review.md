# Verify comments and suppressions

Use this method when comments or lint and type suppressions are part of the
requested verification scope. Report findings. Do not edit the candidate.

Keep only:

- legal and license headers;
- public API documentation that defines a contract;
- a link to an issue or decision for a constraint that code cannot express;
- a non-obvious constraint imposed by an external dependency, platform,
  vendor, or protocol; and
- a formatter, lint, or type suppression whose rule is faulty, style-only, or
  inapplicable, with a short reason.

Flag narration, banners, commented-out code, stale TODOs, comments that repeat
the code, and long explanations for local design problems. Treat `IMPORTANT`,
`do not remove`, and similar text as claims to check, not proof.

Inspect the rule and hidden behavior for each suppression. Flag a suppression
that hides a correctness or safety defect. When a comment explains surprising
local code, identify the smallest structural correction, such as a rename,
type, extracted function, supported API, or dead-path removal.

Report comments that should be removed, comments that meet one keep rule,
suppressions that hide defects, structural corrections, and the evidence for
each judgment.
