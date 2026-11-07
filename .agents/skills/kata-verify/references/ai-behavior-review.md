# Verify AI behavior

Use this method for an existing AI feature, agent, prompt, model configuration,
or other candidate whose output can vary across executions. Do not use it to
author the candidate or tune on the final evaluation cases.

## Fix the evaluation contract

Before a run, record:

- the candidate identity, including code, prompt, configuration, model, and
  dependency versions that can change the result;
- capability cases for the new required behavior and regression cases for
  behavior that must remain stable;
- the case inputs, expected observable results, grader, run count, environment,
  randomness controls, budget, and stop rule; and
- the tuning cases, final cases, and any prior exposure that can contaminate a
  final result.

Do not change the candidate, cases, grader, run count, or pass rule during a
comparison. Start a new labeled evaluation when one of these inputs changes.
Case order can be randomized to reduce order effects. Block or report material
environment differences instead of mixing them into one comparison.

## Select graders

Use a deterministic grader for structure, exact state, executable behavior,
tests, schemas, calculations, and machine-checkable constraints. Use a model
grader only for a stated open-ended judgment that deterministic evidence cannot
decide. Calibrate it with clear passing and failing examples, fixed criteria,
and blind candidate labels when practical. Use a human grader for accountable
value, policy, safety, or subjective quality decisions.

A model grader cannot be the only proof for a condition that executable code
can check. Agreement between graders is evidence about the graders; it does not
replace direct evidence about the candidate.

## Run and judge

Treat each fresh candidate execution as one independent trial. Repeated scoring
of one saved output is not repeated execution. Report each case and trial before
an aggregate result.

- Capability evidence asks whether at least one allowed attempt can produce the
  required result.
- Reliability evidence asks whether all required independent trials continue to
  pass.
- Regression evidence compares the same cases, graders, and environment with a
  fixed baseline.

Use `pass@k` or `pass^k` only when `k`, the sampling method, and trial
independence are stated. Do not infer a population reliability claim from a few
hand-picked cases. Report counts, observed rates, failures, uncertainty, token
or call cost when measured, and the exact population to which the result
applies.

Do not start a paid, external, or high-volume evaluation without explicit
authority and a call or cost budget. Stop on a proved material failure when
more runs cannot change the next action.

Return Pass only when every fixed material condition meets its rule. Return
Fail for a proved condition failure, Unknown for insufficient or contaminated
evidence, and Blocked for missing access, budget, authority, or an accountable
grader. For Kata skill behavior or efficiency, use Dojo only when the current
request explicitly names Dojo.
