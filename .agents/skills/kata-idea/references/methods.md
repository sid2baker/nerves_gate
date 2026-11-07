# Idea methods

Select the smallest method that can settle the current idea.

## Explore

Use Explore for a new or vague idea.

1. Find the problem, beneficiary, current workaround, and desired change.
2. Inspect available facts before asking a question.
3. Surface only the premise gaps that can change the result.
4. Generate two or three meaningfully different directions when alternatives
   exist.
5. Present the alternatives before the recommendation.
6. Confirm the selected direction, scope, success signals, and open questions.

Ask one question per turn. Stop early when the idea is already clear.

## Grill

Use Grill when the user asks for a demanding interview or wants a design,
decision, or proposal sharpened.

Model the work as a decision tree. A decision can be asked only after its
prerequisites are settled. The current **frontier** is the set of decisions
whose prerequisites are settled and whose answers are still open.

1. Build the tree from the user's proposal and current evidence.
2. Remove questions that the environment can answer.
3. Rank the frontier by how much each answer can change the result.
4. Ask the highest-value question. If the user explicitly asks for a rapid
   grilling round, ask at most three independent frontier questions and number
   them.
5. Give a recommended answer and its evidence for each question.
6. Rebuild the frontier after every answer. Do not ask a downstream question
   while its prerequisite is open.
7. End when the frontier is empty or the remaining items are named assumptions.

Grill mode is demanding about missing decisions, not hostile toward the user.
Do not repeat a settled question or make the user defend a fact already proved.

## Challenge

Use Challenge when the user asks to interrogate, pressure-test, find blind
spots, or tear apart an idea.

State the idea's intended outcome first. Then attack it from three different
angles selected from this list:

- the problem is not real or important enough;
- the named beneficiary will not change behavior;
- an existing or smaller solution already wins;
- one hidden dependency makes the idea infeasible;
- misuse, security, privacy, or failure modes defeat the value;
- operating and maintenance cost exceeds the benefit;
- a plausible future change invalidates the premise; or
- the success measure can pass while the user outcome still fails.

For each angle, seek repository evidence, a counterexample, a small calculation,
an existing incident, or a concrete scenario. A concern survives only when it
has support or when the missing evidence is itself a material unknown. Drop
style opinions, generic risks, and claims with no failure path.

Return surviving concerns, dropped concerns, and the smallest test or decision
that resolves each surviving concern. Challenge mode does not repair code or
rewrite the proposal without the user's decision.
