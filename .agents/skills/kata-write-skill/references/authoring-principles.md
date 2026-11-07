# Authoring principles

Apply these rules after the formal contract is resolved. They control how much
instruction to add and where to put it.

## Start with the outcome

Write the result, next consumer, and one observable done condition before any
workflow. Include intent only when it changes the approach. Distinguish the
completed assigned result from an intermediate step, handoff, or blocked result.

Use conditions instead of case lists. State the property that decides behavior.
Keep a list only when every item is required coverage. Add a local done check
only at an unsafe or fragile transition.

## Make continuation explicit

Apply the continuation rules in `library-contract.md`. Place the next recovery
action at the failure branch that needs it. Remove unconditional stops at
recoverable failures and do not make a handoff complete a larger request.
Keep genuine authority gates, review points, read-only boundaries, and resource
limits. Add only the rules needed by this skill's role; do not copy a generic
autonomous loop into every package.

## Separate protocol from judgment

Protocol is a falsifiable field, gate, order, count, scope, authority boundary,
evidence rule, coverage floor, failure branch, or handoff. Keep it explicit.

Judgment selects among valid ways to satisfy the outcome. Leave it open when the
outcome and protocol are sufficient. Add only the smallest principle that
closes a demonstrated behavior gap.

Match freedom to fragility:

- Use high freedom when several approaches are valid.
- Use medium freedom when one pattern is preferred. Give one parameterized
  default or example.
- Use low freedom when one known-good command, format, or order protects a
  fragile invariant. State it once with an ordered failure path.

## Make activation portable

Treat the name and description as an activation contract. Front-load the
distinctive result or mechanism. Add one observable condition for each real
branch. Add an adjacent non-trigger only when another skill can receive the same
words but owns a different result.

Describe capabilities and observable behavior before named tools or host syntax.
Keep invocation flags and command spelling in host adapters. Preserve a direct
use path when automatic routing is unavailable.

## Control context cost

Keep the outcome, required protocol, load-bearing routes, authority envelope,
and done condition inline. Move substantial branch-only, specialist, schema, or
late material to a reference. Put the pointer at the decision point and state
the condition that requires the read.

Keep a line only when it:

- states a falsifiable constraint;
- counters a demonstrated default failure; or
- supplies a fact that the agent cannot derive cheaply.

Delete generic quality language, repeated meanings, stale rules, and copies of
configuration or directory facts that are easy to inspect. Keep each meaning in
one authoritative place. Move or remove complete units instead of compressing
clear sentences into dense prose.

## Keep authority and responsibility bounded

Use one compact authority envelope for consequential work. State the authority
source, target, permitted actions, exclusions, and confirmation condition once.
Inherited authority can narrow but cannot broaden. Higher-priority limits remain
in force.

Name participant roles only when their authority or relationship affects the
result. Delegation needs a distinct scope, output, authority envelope, and
synthesis owner. It does not transfer integration or acceptance responsibility
unless the assignment says so.

## Verify in proportion to risk

Always check mechanical contracts that the repository can test deterministically.
Select behavioral checks for the largest risks introduced by the change:

1. positive, adjacent-negative, and deliberate activation when routing changes;
2. ordinary workflow behavior rather than a prompt that names the expected
   check;
3. the weakest realistic supported execution layer when protocol loss is a
   risk;
4. a capable layer when added prose can reduce judgment or restraint; and
5. the next consumer's ability to use the result without clarification.

When continuation or stopping behavior changes, check a recoverable failure,
an unchanged failure that needs a new approach, and a real authority or resource
limit. Confirm that report-only requests and verifier independence still hold.

Use an isolated boundary for side effects. Size the checks to the skill's reach,
mutation risk, and contract change. Record the exact skip reason for a required
check that does not run. Mechanical success alone does not prove behavior.
