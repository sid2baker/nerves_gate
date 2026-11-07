# Verify a code change

Use this method for a diff, branch, patch, or pull request.

1. Fix the review range. Record the base, head, worktree state, and exact diff.
   Do not review an ambiguous range.
2. State the change intent from the request, plan, issue, commit messages, and
   current product contract. Mark intent unknown when those sources conflict.
3. Read the repository rules that govern the changed paths. Do not apply a
   personal style rule as a project requirement.
4. Review along these axes:
   - intent and acceptance conditions;
   - correctness and failure handling;
   - tests and observable behavior;
   - security and sensitive data;
   - compatibility and effects outside the diff; and
   - maintainability only where it creates a concrete defect or carrying cost.
5. Follow changed contracts to callers and consumers when the visible diff is
   not sufficient proof. Use the blast-radius method for a material external
   effect.
6. Run the smallest check that can prove each important finding. A source-only
   finding must name the complete failure path and why an executable proof is
   unavailable.

Keep a finding only when it identifies a violated requirement, wrong behavior,
unsafe state, or concrete maintenance failure. Drop preferences, speculative
future risks, and findings that the current code or a run disproves.

Report findings first, ordered by consequence. Each finding contains the source
location, violated intent or rule, failure path, evidence, and smallest repair
direction. Merge findings with one root cause. Report the reviewed range,
checks, coverage limits, and “no supported findings” when appropriate. Do not
apply a repair.
