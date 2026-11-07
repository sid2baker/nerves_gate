# Kata Dojo runner

Use this runner only after the user explicitly requests Dojo in the current
task. Do not run it as a default test, catalog, formatting, or verification
path for changes elsewhere in Kata.

Read this adapter only when the current repository contains the Kata `dojo/`
application and its `mix.exs` file.

## Preflight

Read `dojo/README.md` and the selected suite before a command. Confirm that the
candidate, suite inputs, checks, profile, and saved context match the assignment.
Run commands from `dojo/`. Do not install dependencies or repair the runner as
part of an evaluation.

The main command shape is:

```text
mix skill.eval SUITE train
mix skill.eval SUITE tune --attempts N --max-calls N --max-tokens N
mix skill.eval SUITE verify --candidate PATH
mix skill.eval SUITE check --context CONTEXT_ID
mix skill.eval SUITE score --context CONTEXT_ID --batch BATCH
mix skill.eval SUITE status --context CONTEXT_ID
```

Read the local command help before use because required flags can change. A
live `train`, `tune`, or `verify` command needs the explicit budget and profile
from the assignment. `check`, `score`, and `status` can reuse saved evidence and
must not make a live call unless the local help states this clearly and the
assignment permits it.

## Promotion evidence

Use the runner's current outcome and scoring rules. For the present runner, a
promotion recommendation needs all required outcomes to pass, complete cost
measurements, repeated source and candidate verification on the full case set,
an improved score against the fixed source, exact tested candidate text, and a
review of behavior outside the checks.

Keep immutable execution records. If a checker changes, save a new assessment
of the old output. Do not rewrite the old execution or treat the reassessment as
a new model run.
