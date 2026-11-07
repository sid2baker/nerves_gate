# Jido routes

The human can state a goal in normal language. The names below are optional
entry overrides and help terms. Do not ask the human to choose one when the goal
already selects a route.

## Value-delivery steps

| Step | Trigger | Non-trigger | Primary Kata | Default authority |
| --- | --- | --- | --- | --- |
| `understand` | Establish the current condition, explain a cause, answer a domain question, or bound an unclear problem. This includes a repeated-mistake claim without evidence of two occurrences. | The current condition and work target are already supported. | `../kata-understand/SKILL.md` | `read-only` |
| `idea` | Explore, grill, or challenge what to build before implementation planning. | Product behavior, scope, and success signals are already settled. | `../kata-idea/SKILL.md` | `local-write` |
| `roadmap` | Create, advance, or report a durable decision roadmap for a clear long-horizon initiative. | The destination is unsettled, the route fits one planning session, or only implementation units remain. | `../kata-roadmap/SKILL.md` | `local-write` |
| `scope` | Turn a rough request with a clear purpose into bounded delivery work, exclusions, and completion evidence. | The work boundary and acceptance contract are already clear, or the desired behavior still needs an idea decision. | `../kata-scope/SKILL.md` | `local-write` |
| `plan` | Create or deepen a software implementation plan with material technical decisions, dependencies, or several coordinated units. | The request is non-software, already executable, or only asks for an answer. | `../kata-plan/SKILL.md` | `local-write` |
| `delegate` | Assign defined work to available workers or supervise its return with check, watch, or drive. | The work boundary is unresolved, one direct worker route is sufficient, or no assignment or follow-through is requested. | `../kata-delegate/SKILL.md` | `local-write` |
| `work` | Produce a candidate from a request with known target, scope, acceptance, and authority. This includes an explicitly requested repository guard with evidence of at least two occurrences. | A material value decision or route remains open, repeated-mistake evidence is missing, or a candidate already exists. | `../kata-work/SKILL.md` | `local-write` |
| `verify` | Check an existing candidate against its acceptance conditions. | The result still needs to be produced or repaired. | `../kata-verify/SKILL.md` | `read-only` |

## Leadership learning

| Step | Trigger | Non-trigger | Primary Kata | Default authority |
| --- | --- | --- | --- | --- |
| `tutor` | Teach, coach, or give adaptive practice on leading agent work through a real task. | The user asks only to perform the work, or requests feedback about a skill package rather than learning feedback. | `../kata-tutor/SKILL.md` | `read-only` |

## Kaizen steps

| Step | Trigger | Non-trigger | Primary Kata | Default authority |
| --- | --- | --- | --- | --- |
| `maintain-skill` | Capture feedback on a skill or resolve one supported library finding when the disposition or required change is not known. `feedback` is an entry alias. | Feedback on an unrelated artifact, or a known package change ready to write. | `../kata-maintain-skill/SKILL.md` | `local-write` |
| `write-skill` | Create, import, convert, or revise a skill package with a known contract. | The library concern still needs a finding or ownership decision. | `../kata-write-skill/SKILL.md` | `local-write` |
| `dojo` | The request explicitly names Dojo and asks to inspect saved evidence or evaluate an exact candidate. | Any inferred need for testing, verification, efficiency evidence, or adoption support. | `../kata-dojo/SKILL.md` | `local-write` |

## Support steps

| Step | Trigger | Non-trigger | Primary Kata | Default authority |
| --- | --- | --- | --- | --- |
| `docs` | Establish or maintain project docs, process an inbox item, preserve durable project knowledge, reconcile selected docs with code, or create, audit, and refresh project orientation. `docs refresh` explicitly refreshes the scoped `README.md` and `AGENTS.md` files. `orient` is an entry alias. | Author a plan, write one selected technical artifact without an orientation decision, or make a product decision about disputed content. | `../kata-docs/SKILL.md` | `local-write` |
| `status` | Report local or remote Git workbench state for a repository or folder. | Application health, business status, or general progress. | `../kata-sitrep/SKILL.md` | `read-only` |
| `shipit` | A bare `shipit` means commit, push, and create or update a PR for the accepted verified change. Honor a requested direct push, commit only, watch, or merge. | The accepted change or target is unclear, or required verification is missing. | `../kata-shipit/SKILL.md` | `external-write` |
| `help` | Explain available routes with natural-language examples. | A request to perform work. | None | `read-only` |

## Selection rules

1. Determine what the requested result changes. A current domain result uses
   value delivery. A request to learn how to lead agent work uses tutoring. A
   reusable skill or work method uses Kaizen. Project docs, Git status,
   shipping, and help use support.
2. Honor an explicit step only as an entry request. Continue to a later step
   only when the user's requested result and authority include it.
3. Without an explicit step, select the first unresolved contract in
   `loops.md`. Never infer Dojo as that step.
4. Re-evaluate against the whole request after every step. Return a failed gate
   to its repair owner within the granted authority, then verify again. Stop at
   the requested result, an explicit review point, cancellation, an execution
   limit, or an unavailable decision, authority, capability, or dependency that
   prevents further authorized progress.
5. Do not make the human repeat the request with an internal term.

`$jido feedback ...` selects the feedback entry in `maintain-skill` when the
subject is a skill or its workflow. Feedback alone permits capture and
inspection, not a repair or external submission. The target owns the optional
local remedy explanation, optional sharing channels, and explicit submission
opt-in. Do not add a separate feedback skill.

Examples:

```text
$jido explain why customer renewals fell last quarter
$jido tutor help me learn to give an agent a clear first assignment
$jido grill this product idea before we plan it
$jido create a decision roadmap for this long-horizon initiative
$jido scope this launch recommendation before we assign the work
$jido delegate the research units and return checked results for integration
$jido prepare a launch approach from these constraints
$jido update this report to meet the supplied acceptance rules
$jido check whether this result meets the contract
$jido make this repeated review process reusable
$jido feedback on shipit: I expected a PR, but it stopped after a local commit
$jido dojo inspect the saved evidence for this skill
$jido record this verified finding in the project docs
$jido docs refresh this project's README.md and AGENTS.md files
$jido ship the accepted verified change as a pull request
```
