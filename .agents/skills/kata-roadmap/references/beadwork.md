# Beadwork Roadmap Backend

Use this backend only in an installed, already initialized local Beadwork
repository. Beadwork is the required backend when more than one writer can
advance a roadmap.

## Preconditions

Resolve the Git root and check without changing state:

```sh
command -v bw
bw -C <git-root> list --all --json
```

If either command fails, stop this backend. Do not run `bw init`, `bw upgrade`,
`bw sync`, or a repair command. A new roadmap can fall back to CSV only when no
parallel writer is possible.

## Representation

Create one epic for the roadmap. Its description contains the roadmap
container fields from `roadmap-contract.md` and the stable Roadmap ID. Apply
the label `roadmap`.

Create one child task for each sharp decision. Its title starts with the stable
decision ID. Its description contains the question, kind, interaction, owner,
review point, expected evidence, stable blockers, and roadmap ID. Apply:

- `roadmap:decision`; and
- one of `roadmap:discussion`, `roadmap:research`, `roadmap:prototype`, or
  `roadmap:enabling-task`.

Keep fog and the low-resolution resolved-decision index in the epic
description. Do not create a child task for fog.

## Create and wire

Search existing descriptions for the stable Roadmap ID before creation. Reuse
matching state. Stop on a conflicting duplicate instead of deleting or
replacing it.

Create the epic, then all current decisions, then dependency edges in a second
pass:

```sh
bw -C <git-root> create "<title>" --type epic --description "<body>" --silent
bw -C <git-root> label <epic-id> +roadmap
bw -C <git-root> create "D<n>: <title>" --type task --parent <epic-id> --description "<body>" --silent
bw -C <git-root> label <decision-id> +roadmap:decision +roadmap:<kind>
bw -C <git-root> dep add <blocker-id> blocks <blocked-id>
```

Use only canonical decision dependencies. Do not add edges only to force a
preferred order.

If a write fails, stop further writes. Preserve and report every returned ID.
Do not clean up partial state automatically.

## Claim and resolve

Read the roadmap and child state immediately before a claim. Use `bw start` so
Beadwork rejects blocked work and records the assignee:

```sh
bw -C <git-root> start <decision-id> --assignee <owner> --json
```

Do not replace another active assignee. Record the detailed resolution as a
comment, close the decision, and update the epic's low-resolution decision
index:

```sh
bw -C <git-root> comment <decision-id> "<resolution and evidence>" --json
bw -C <git-root> close <decision-id> --reason "resolved" --json
bw -C <git-root> update <epic-id> --description "<reconciled roadmap body>" --json
```

Create newly sharp decisions before wiring their dependencies. When a decision
moves out of scope, comment with the reason, close it with reason
`out-of-scope`, and add its pointer to the epic's Out of scope section.

## Read and verify

Read state back after each write group:

```sh
bw -C <git-root> show <epic-id> --json
bw -C <git-root> list --parent <epic-id> --all --json
bw -C <git-root> show <decision-id> --json
```

Compute the roadmap frontier from its complete child list and the status of
each named blocker. Do not use the repository-wide `bw ready` result as the
roadmap frontier. It can include the epic or omit children. Do not treat
unrelated repository issues or the epic itself as roadmap decisions.

Confirm:

- one epic carries the stable Roadmap ID;
- every sharp decision maps to exactly one child task;
- every stable blocker maps to one edge in the correct direction;
- no extra edge changes the frontier;
- active decisions have one assignee;
- resolved decisions have a resolution comment and closed state;
- fog exists only in the epic description; and
- the reported frontier matches the saved graph.

Mark the epic complete only after the completion invariants pass. Never close
its subtree recursively.
