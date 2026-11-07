# Convert or revise an existing skill

Use this route when an existing skill must meet the current library contract or
when a canonical skill needs a bounded revision.

1. Resolve the canonical source package. A local directory is not proof of
   ownership. If ownership or reuse rights are unclear, complete the external
   preflight in `import.md` before any target change.
2. Read the complete package and find its callers. Record its current outcome,
   triggers, supported metadata, resources, safety rules, notices, and
   verification behavior.
3. Map the existing behavior to the reusable work specification in
   `library-contract.md`. Preserve useful behavior. Remove duplication and
   accidental host assumptions. Do not change scope only to fit the template.
   Check early handoffs, failed-check branches, and retry limits against the
   continuation rules. Preserve review points, authority, and resource limits.
4. Identify participant roles only when their authority or relationship matters.
   Separate the reusable skill boundaries from authority granted by a specific
   invocation.
5. Write the faceted metadata from the library contract. Preserve supported
   metadata and remove any legacy subject row for this skill.
6. Preserve required resources, callers, source identity, license text,
   attribution, and unrelated behavior. Record material changes.
7. Re-run representative requests for the old behavior and the converted
   contract. Verify the completion conditions and taxonomy metadata.

A one-run preference belongs in the active request. A repository-wide
preference belongs in the active repository instructions. Add a preference to
the skill only when the user confirms that it is stable and specific to that
canonical skill.

Do not mine chat or repository history for preferences unless the user names the
source and range. Confirm each inferred pattern before it becomes a skill rule.
