# Assignment contract

Use this portable form for each delegated unit:

```text
Assignment: <stable short identity>
Outcome and purpose: <observable result and why it matters>
Context and inputs: <sources, prior decisions, and dependencies>
Expected output: <format, location, or return shape>
Worker: <person, agent, or unassigned>
Integration owner: <owner who accepts and combines the return>
Allowed actions: <actions the worker can take>
Reserved decisions: <decisions that return to the owner>
Limits: <time, calls, cost, tools, or other relevant limits>
Done when: <completion checks and evidence>
Return with: <result, evidence, changes, risks, and open questions>
Report when: <progress point, blocker, decision limit, or failure>
Recovery: <next authorized action and repair owner when separate>
Stop when: <completion, blocker, limit, cancellation, or other condition>
```

Do not invent a worker, deadline, budget, or authority. Mark an absent worker
as `unassigned`. Omit a limit only when it is not relevant; never imply that
resources are unlimited.

## Return contract

The worker returns:

```text
Assignment: <identity>
State: <complete|partial|blocked|failed>
Result: <candidate or location>
Evidence: <direct checks and sources>
Changed state: <files, records, or systems changed>
Unresolved: <questions, risks, and missing inputs>
Recommended next owner: <repair, verification, integration, or decision owner>
```

A worker's `complete` state is a claim. The integration owner or verifier checks
the return against the assignment before acceptance.
