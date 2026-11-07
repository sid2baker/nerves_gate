# Work brief

Use the smallest form that preserves the contract. Plain text is the portable
format. Do not require a tracker, template engine, or another skill.

## Compact form

```text
Outcome: <observable result and purpose>
Includes: <required work>
Excludes: <nearby work outside this assignment>
Done when: <acceptance conditions and evidence>
Inputs and dependencies: <sources, prior decisions, conditions, known owners>
Authority: <allowed actions and reserved decisions>
Open decisions: <question and accountable owner, or none>
Next owner: <worker, planner, delegator, verifier, or work owner>
```

Add delivery units only when division is useful:

```text
Unit: <stable short name>
Result: <one coherent output>
Depends on: <units, inputs, or decisions>
Owner: <known owner or unassigned>
Done when: <unit evidence>
```

## Quality checks

- The outcome names a result, not only an activity.
- Each inclusion supports the outcome.
- Exclusions prevent likely boundary confusion.
- Completion conditions are observable by the result consumer.
- Proposed values are labeled as proposals.
- Unknown owners, dates, costs, and decisions remain visible.
- A unit can return a useful result without writing into another unit's mutable
  state, or the shared-state owner and sequence are explicit.

Do not turn a compact assignment into a long artifact when one paragraph is
enough. Do not describe a proposal as an accepted commitment.
