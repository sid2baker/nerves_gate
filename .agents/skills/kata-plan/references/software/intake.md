# Software Plan Intake

Use this stage to prove that the assignment is a software planning task and to
resolve its source, repository, output, and decision boundary before deep
research.

## Resolve the target

Resolve one target repository in this order:

1. a repository or path named by the user;
2. the repository that contains an explicit Product Contract, decision
   roadmap, or plan path;
3. the current working repository; or
4. no repository, when the user supplied enough source material for a paper
   plan.

Do not search unrelated sibling repositories to avoid a missing choice. When
more than one target remains plausible, ask which one owns the work.

For a repository target, read its active instructions and entry-point README.
Inspect Git status before any write. Record existing changes that overlap the
plan path or the software surface. Do not absorb or undo them.

## Classify the input

Select one input route.

### Product Contract

A Product Contract supplies the product outcome and stable behavior. Accept:

- `artifact_contract: kata-plan/v1` with `artifact_readiness:
  requirements-only`; or
- legacy `artifact_contract: ce-unified-plan/v1` with the same readiness.

Enrich a Markdown Product Contract in place. Preserve its Goal Capsule,
requirements, acceptance examples, scope, decisions, and sources. Add the
Planning Contract and implementation sections after the Product Contract. Do
not change a product decision without the accountable owner's confirmation.

### Decision roadmap

Accept a `kata-roadmap` result only when its backend state is complete and its
planning handoff names the destination, fixed decisions, constraints, sources,
and target repository or delivery context. Read the roadmap container and the
full resolution of each decision that controls product behavior, risk, or a
technical boundary. Do not import fog, active decisions, or an incomplete
frontier as settled planning input.

Preserve stable decision IDs and cite the Beadwork roadmap ID or CSV path. If
the roadmap is active or blocked, stop before technical design and report the
remaining decision owner and frontier.

### Understood context

Supported investigation results can replace repeated discovery when they name
their target state, evidence, limits, and date. Recheck facts that are cheap,
consequential, or likely to have changed. Do not treat an explanation of the
current system as a decision about the target system.

### Direct request

A direct request is ready when it states or clearly implies all of these facts:

- the software outcome;
- the users or systems affected;
- in-scope and out-of-scope behavior;
- acceptance signals; and
- the target repository or supplied technical context.

Capture these facts in the plan. Do not manufacture a broader product brief.

### Existing implementation plan

Update an existing plan only when the user gives its path or the target is
unambiguous from the request. Read the complete plan and its current sources.
Preserve stable requirement, decision, and unit IDs. Change an ID only when its
meaning changed, and record the old-to-new mapping.

Do not use the plan as a progress log. Current implementation state belongs in
repository evidence or a separate execution record.

## Check product readiness

Before technical planning, confirm that no missing answer can change:

- the beneficiary or requested behavior;
- scope or success criteria;
- authentication, authorization, or privacy policy;
- stored data meaning or retention;
- a public API or compatibility promise;
- external side effects or approval policy; or
- the operating objective and acceptable failure behavior.

Inspect available evidence before asking the user. Ask one decision at a time.
Give a recommended default only when repository evidence supports it.

If a product decision remains open, stop before technical design. Either wait
for the answer or write a `planning-blocked` artifact that states the question,
its owner, and the plan sections it blocks. Do not turn a product choice into a
technical assumption only to finish the plan.

## Separate planning from diagnosis and work

A known defect with a supported cause can be planned when its repair has
several technical decisions or dependent steps. An observed failure with an
unknown cause needs diagnosis before planning. A ready one-step change can be
implemented without planning unless the user invoked this skill directly.

Planning can inspect and execute safe read-only discovery. It does not edit
product code, run a migration, install a dependency, or test a proposed
implementation that does not exist.

## Resolve outputs

Parse only explicit output requests:

- Markdown is always the canonical format.
- `output:html`, “HTML,” or an equivalent request adds an HTML view.
- `beadwork` or a clear issue-graph request adds Beadwork materialization.
- `chat-only` suppresses a file write.

Do not enable Beadwork because the command happens to be installed. Do not
produce CSV. If the user requests an unsupported adapter, keep the Markdown
plan and report the adapter limit.

For a new repository plan, use the established plan directory. If none exists,
use `docs/plans/`. For a new non-repository plan, default to chat. Never
overwrite an unrelated artifact.

## Intake result

Do not leave intake until these values are known:

- target repository or supplied source boundary;
- input route and source identity;
- product-readiness state;
- requested canonical and optional outputs;
- target plan path or chat-only state;
- accepted authority; and
- accountable owner for any blocking decision.
