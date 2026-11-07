# Record durable project knowledge

This route accepts a direct user request or a `project-knowledge-capture` from
another skill. The input must identify the subject, why later work needs it,
the content to preserve, supporting evidence, related artifacts, and active
write authority. Natural language is sufficient.

Record the knowledge only when all these conditions hold:

- It will help work after the current task.
- Its material claims have inspectable evidence or an accountable accepted
  decision.
- Code, tests, an existing document, the active plan, and commit history do not
  already communicate it well enough.
- Its destination and status do not require an unresolved product or
  architecture decision.

Choose the destination from the document contracts:

- A repeatable task goes in a guide.
- Current system facts go in reference.
- A settled choice with reasons and consequences goes in decisions.
- A verified reusable finding with conditions of use goes in lessons.

Planning workflows own plan creation. Register and maintain an existing plan,
but do not turn a capture request into a new plan. When evidence is incomplete,
place the material in the inbox with its provenance and an unverified status, or
return a capture-ready handoff when writes are not authorized.

Inspect the supplied evidence. Preserve the caller's meaning, but do not treat
the caller's confidence label as proof. Update an existing owning page instead
of creating a duplicate. Link evidence and related plans, decisions, reference,
and lessons instead of copying them.

Verify that the recorded page says no more than its evidence supports, uses the
correct status, appears in the index when useful, and leaves no duplicate owner
for the subject.
