# Build the Software Work Graph

Divide the technical design into implementation units that a fresh executor can
complete and verify without reconstructing the whole plan. The units form a
directed acyclic graph. They are not a layer-by-layer task list.

## Prefer complete behavior slices

Each unit should deliver one coherent behavior, contract, migration stage, or
integration result. A normal unit crosses the layers needed to make that result
real and testable.

Good unit boundaries include:

- one end-to-end behavior behind an existing interface;
- one additive interface plus its first real consumer;
- one safe migration stage;
- one compatibility bridge;
- one independently measurable performance change; or
- one final removal after all callers moved.

Avoid units such as “models,” “API,” “UI,” and “tests” when none is useful or
verifiable alone. Tests belong with the behavior they prove unless a separate
test harness is itself a required deliverable.

## Use stable identities

Assign `U1`, `U2`, and so on in dependency order. Preserve an existing unit ID
when its meaning remains the same. If an update splits, merges, or replaces a
unit, record the mapping and update every dependency and requirement link.

Do not use issue tracker IDs as unit identities. Optional adapters map stable
unit IDs to external or local tracker IDs.

## Define each unit

Each unit must state:

- **Outcome:** The behavior or contract that exists when the unit is done.
- **Requirements:** The Product Contract requirements it advances.
- **Dependencies:** Other unit IDs that must finish first, or `None`.
- **Affected surfaces:** Grounded files, modules, interfaces, data, tests, and
  documentation, with the reason each surface changes.
- **Implementation direction:** The required structure, sequence, and
  invariants. Leave ordinary coding choices to the executor.
- **Test scenarios:** Observable success, failure, boundary, and regression
  cases that belong to this unit.
- **Verification:** The direct checks or commands that prove the unit result.
- **Completion signal:** The exact state that permits dependent units to start.

An affected surface can be a package, module, or interface when an exact file
does not yet exist. Do not invent a path to make the plan look precise.

## Size units for bounded execution

A unit should fit one focused execution pass with the repository context it
names. Split a unit when it contains several independent behaviors, unrelated
risks, separate migrations, or more context than a fresh executor can hold.

Do not split tightly coupled changes only to reduce line count. Keep atomic
changes together when partial completion would break the repository, violate a
contract, or leave data unsafe.

## Handle wide changes safely

Use expand, migrate, and contract for a wide rename, schema change, protocol
change, or shared-interface replacement:

1. **Expand:** Add the new form beside the old form and keep existing consumers
   working.
2. **Migrate:** Move consumers in independently verifiable batches when
   possible.
3. **Contract:** Remove the old form only after evidence shows that no supported
   consumer remains.

If intermediate commits cannot stay valid, state the integration boundary and
the first point where the complete repository must pass. Do not pretend that
unsafe partial units are independently shippable.

## Define dependency truth

Add an edge only when a unit cannot begin safely before another unit completes.
Do not use dependencies to express preference, ownership, or presentation
order.

For each edge `U<n> -> U<m>`, be able to state the artifact, contract, data, or
decision that the first unit supplies to the second. Remove circular edges by
changing the unit boundary or introducing a small shared prerequisite.

Identify:

- the initial frontier, which is every unit with no blocker;
- units that can run in parallel;
- the integration or migration critical path; and
- the final unit that proves removal, rollout, or repository-wide completion.

## Preserve traceability

Every in-scope requirement must appear in at least one unit and one verification
scenario. Every unit must support at least one requirement, technical decision,
or necessary integration condition. Record a deliberate deferral instead of
leaving an uncovered requirement.

Use a compact matrix when the plan has more than a few requirements or units:

| Requirement | Units | Verification |
| --- | --- | --- |
| R1 | U1, U3 | behavior test and integration gate |

## Separate plan and progress

The work graph describes the intended dependency structure. It does not record
percent complete, current assignee, temporary branch, or execution notes. Keep
progress in the execution system or optional issue tracker.

## Work-graph review

Before verification design, confirm:

- every unit has one observable outcome;
- each unit is coherent and bounded;
- dependencies have a real gating reason;
- no cycle exists;
- the initial frontier is clear;
- risky migrations and removals use safe stages;
- product requirements and technical decisions have unit coverage; and
- an executor can read one unit plus its cited contracts without reading the
  whole plan first.
