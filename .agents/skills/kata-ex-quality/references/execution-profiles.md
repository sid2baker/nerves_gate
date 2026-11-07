# Execution profiles

Use these profiles to recommend the minimum reasoning capability for each phase.
They are portable. Do not name one model vendor or product in the skill output.
A profile is guidance, not authority to change models, delegate work, or apply a
finding.

## Reasoning profiles

| Profile | Suitable work | Stop or escalate when |
| --- | --- | --- |
| `low` | Run an inspected deterministic command, validate CSV data, group exact messages, or apply a formatter result. | Source meaning, ownership, or test behavior needs interpretation. |
| `medium` | Confirm a bounded source finding, make a local mechanical correction, improve one fixture, or verify focused behavior. | The change affects concurrency, a public contract, a dependency direction, or an unclear abstraction. |
| `high` | Analyze OTP coordination, order dependence, dynamic use, public contracts, wire behavior, architecture, or abstraction ownership. | Required policy or ownership is not established. Record `judgment-required`; more reasoning does not supply missing authority. |

Use a code-capable model for source changes. A fast tool-capable model is enough
for deterministic collection and data maintenance. Prefer a fresh medium or high
reasoning pass for independent verification of a risky batch.

Standard discovery normally starts at `medium` and elevates individual rules.
Thorough data-foundation or OTP discovery requires `high` because it traces
ownership and contracts across layers. Keep deterministic gate collection at
`low` or `medium` even during a thorough run.

## Phase routing

Do not run the entire quality climb at its highest profile. Use the profile for
the current phase:

1. Collect configured evidence at the rule's confirmation profile.
2. Raise the confirmation profile when source context adds risk.
3. Confirm the finding and class before application.
4. Apply at the rule's application profile or higher.
5. Verify at `medium` by default. Use `high` for concurrency, architecture,
   public contracts, dynamic consumers, and disputed equivalence.

Use the highest required application profile for one batch. Split a batch when a
high-reasoning item would make unrelated mechanical work harder to attribute.

## Mandatory elevation

Use `high` reasoning for confirmation and application when any of these facts
apply:

- process ordering, monitoring, supervision, cleanup, or time controls behavior;
- a public API, data format, protocol, callback, or wire contract can change;
- dynamic lookup, configuration, macros, generated code, or external consumers
  can hide use;
- a new shared abstraction or dependency direction needs an owner; or
- architecture policy or supported behavior has more than one valid reading.

High reasoning does not make a finding safe. If the owner, policy, or required
behavior is unknown, classify the item as `judgment-required`.

## Command effects

Classify a command before it runs. A command can have more than one effect.

| Effect | Meaning | Default in `scan` mode |
| --- | --- | --- |
| `read-only` | Reads source and emits terminal output only. | Allowed. |
| `build-write` | Compiles or updates build artifacts. | Not allowed. Use existing evidence or select a mode that permits the effect. |
| `cache-write` | Creates or changes a tool cache. | Not allowed. Use existing evidence or select a mode that permits the effect. |
| `report-write` | Creates coverage, analysis, or other report files. | Not allowed. Use existing evidence or select a mode that permits the effect. |
| `network` | Contacts a package source, service, or provider. | Requires separate authority. |
| `external-state` | Changes a task system, CI, database, or other external state. | Not allowed without separate authority. |

Inspect an alias, task implementation, or project policy before assigning an
effect. Do not assume that a check is read-only because its name contains
`check`.

## Report guidance

Report one recommendation for discovery and one for each proposed batch. Name
the cause of every elevation. When the current model or reasoning level is not
visible, report the required profile without claiming that the current model is
sufficient or insufficient.

Example:

```text
Execution guidance
- Discovery: medium reasoning.
- EXQ-B-20261104-01: medium; local fixture extraction with focused tests.
- EXQ-0042: high confirmation; the proposed owner crosses an OTP boundary.
- Automatic application stopped for EXQ-0042 because ownership is unknown.
```
