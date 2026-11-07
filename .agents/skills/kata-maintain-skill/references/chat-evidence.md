# Use chat history as maintenance evidence

Use this method only when the operator asks to learn from conversation history
and names the conversations, project, or date range that can be inspected. The
result is one maintenance finding or a `workflow-learning-brief`; it is not a
chat summary and does not silently create persistent guidance.

## Evidence record

For each relevant example, record a safe task identity or date, the user-owned
statement or correction, the trigger, the affected work step, the requested
decision rule or quality bar, the observed result, and counterevidence. Do not
expose transcript paths, credentials, customer data, private content, or
unrelated conversation text.

Classify each example:

- explicit: the user states a stable preference or asks to encode it;
- correction: the user changes agent behavior or rejects a result;
- repeated friction: the same avoidable problem occurs in at least two tasks;
- successful pattern: the user accepts the same material workflow choice in at
  least two tasks;
- weak: the agent chose the behavior and the user gave no clear signal;
- contradicted: comparable tasks support incompatible rules.

One task-specific correction does not prove a durable rule. It can support a
finding only when the user confirms that it is stable, or another comparable
example supports the same rule. Weak evidence cannot become a skill rule.
Contradicted evidence requires the operator to resolve the scope or preference.

## Select the owner

- Put a personal, cross-project preference in the user's approved preference or
  memory location.
- Put a repository-specific rule in that repository's active instructions.
- Put a repeatable multi-step method with a clear trigger and checkable result
  in its canonical skill.
- Keep useful but non-triggerable context in project documentation.
- Select no artifact for situational, stale, weak, or contradicted evidence.

The current request must grant authority before any personal data, preference,
memory, repository rule, skill, or workflow document is written. Without that
authority, return the proposed text, evidence strength, owner, scope, expiry or
review condition, and counterevidence as a brief.

Report adopted evidence, considered evidence, dismissed evidence, confidence,
the selected owner, the smallest proposed change, and any decision that blocks
persistence.
