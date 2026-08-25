# Command / Event / State implementation plan

## Frozen architecture

NervesGate uses only three domain concepts:

- **Command** — imperative intent sent to the process that owns the affected state.
- **Event** — completed or observed reality delivered to an FSM or the public projection.
- **State** — private lifecycle truth or the canonical secret-free public projection.

Runtime effects, retries, task supervision, transport envelopes, revisions, and correlation identifiers are implementation machinery. They are not additional domain concepts.

## Non-negotiable invariants

1. Each private fact has exactly one owning subsystem FSM.
2. Each externally mutable resource has exactly one mutation owner or one shared serialization boundary.
3. Mutations against one external resource never overlap unless the external API supplies real fencing.
4. Desired-state changes during a mutation are coalesced and reconciled after the current mutation terminates.
5. Every asynchronous effect has an owner epoch and effect reference.
6. While an owner epoch remains alive, each effect produces at most one accepted terminal event and eventually produces one unless the epoch terminates.
7. Effect workers are supervised, bounded by a timeout where applicable, and cannot outlive their owner epoch unfenced.
8. A restarted FSM treats interrupted effects as ambiguous: load durable desired state, observe reality, then reconcile.
9. Stale completions never mutate private state. Stale external state is prevented through serialization/fencing or explicitly cleaned and reconciled.
10. Cross-FSM workflow correlation uses serializable change IDs. Erlang references remain private.
11. `DeviceState.publish/1` is synchronous, source-authenticated, typed, and recursively secret-safe.
12. DeviceState revisions advance only when canonical public state changes.
13. DeviceState never executes lifecycle commands, derives subsystem lifecycle, persists configuration, heals, or rolls back.
14. DeviceState subscriptions atomically return one snapshot followed by future single-event messages.
15. A revision gap or boot-ID change causes immediate snapshot resynchronization; events are never buffered for replay.
16. Dependencies is restartable projection wiring only. It has no desired state, retries, effects, healing, or persistence.
17. Alarm policy consumes canonical public state, issues remedies as owner commands, and never clears its own evidence.
18. Essential slices hydrate before the initial hardware-watchdog boot handshake completes.
19. A later DeviceState subtree restart reconstructs state without repeating the boot-health decision.
20. Browser, HTTP, CLI, alarm, dependency, and replica consumers use the same snapshot/event protocol.

## External resource ownership

| External resource | Mutation owner / serialization boundary |
| --- | --- |
| Accepted/candidate settings files | `NervesGate.Gateway.Configuration` through `Gateway.Persistence` |
| Uplink interface configuration | `NervesGate.Internet` through `Internet.Platform` |
| Commissioning-only interfaces | `NervesGate.Commissioning` through `Commissioning.Access` |
| Tailscale enrollment/profile intent | `NervesGate.Tailnet` through `tailscale_ex` |
| Tailscale advertised routes | `NervesGate.SubnetRouter` through `tailscale_ex`; calls share the Tailscale server serialization boundary |
| NervesSSH listener | `NervesGate.SSH` through `SSH.Runtime` |
| BEAM distribution | `NervesGate.Cluster` through `Cluster.Distribution` |
| Individual peer connections | one `NervesGate.Cluster.Peer` per peer |
| Alarmist graph and remedy registration | `NervesGate.Alarms.Runtime` |
| Firmware update/trial state | the firmware-update owner; globally serialized and never overlapped |

If implementation inspection shows two owners mutate the same indivisible runtime state, the imperative boundary moves behind one owner before either FSM is changed.

## Phase 1 — executable contracts first

Add tests for:

- pure public event application and typed slice replacement;
- source-authenticated synchronous publication;
- recursive secret rejection;
- deduplication and revision semantics;
- atomic snapshot subscription;
- no-event-buffer replica resynchronization;
- dependency reconstruction from an initial snapshot;
- alarm feedback suppression;
- stale effect completion;
- mutation serialization and desired-state coalescing;
- worker success, failure, crash, timeout, and owner termination;
- restart reconciliation after external success but before completion delivery;
- configuration restart with an outstanding change ID;
- real DeviceState subtree restart and hydration;
- one-time StartupGate boot handshake.

Tests should assert externally visible contracts, not private helper implementation.

## Phase 2 — canonical public state

1. Replace `NervesGate.DeviceState.Data` with `NervesGate.DeviceState.State`.
2. Replace operations/actions/reducers with secret-free public events and `apply_event/2`.
3. Use the public event shape:

   ```elixir
   {:state_reported, source, public_state}
   ```

4. Add typed public status structs for subsystem slices. They may be colocated with their owner module.
5. Keep unhydrated slices as `nil` and track required hydration explicitly.
6. Make all public statuses JSON-safe and recursively reject `%NervesGate.Secret{}`.

## Phase 3 — DeviceState server and clients

1. Start DeviceState before all local publishers.
2. Implement synchronous authenticated publication using the `GenServer.call/3` caller PID.
3. Resolve the expected currently supervised owner for each source.
4. Apply, deduplicate, revise, and broadcast exactly one event per message.
5. Implement monitored atomic subscriptions returning `%{boot_id, revision, state}`.
6. Convert LiveViews, alarms, dependencies, and replicas to apply `State.apply_event/2` locally.
7. Remove per-subsystem browser PubSub reload topics and composite process sampling.
8. Keep each remote gateway independently versioned.

## Phase 4 — subsystem FSM shell

For every lifecycle FSM:

1. Declare `command`, `event`, and `input` types in the owning module.
2. Commands use imperative names; events use past-tense names; states describe current truth.
3. Public API functions call `Finitomata.transition/4`; no generic command bus is introduced.
4. `on_transition/4` changes private state only. It performs no network, storage, daemon, listener, distribution, or alarm side effects.
5. A post-transition listener in the same FSM module synchronously reports public state, then starts state-owned runtime work.
6. Effect-owning transient states store an effect reference before entry.
7. Re-entry intentionally creates a new generation only when the previous mutation has terminated or is fenced.
8. Stale completion events abort softly and do not notify the post-transition listener.
9. Runtime boundaries remain in small `runtime.ex`, platform, persistence, connectivity, and distribution modules when independently meaningful.

## Phase 5 — supervised effect machinery

Add a small implementation helper under `NervesGate.FSM` that:

- starts a coordinator under `NervesGate.TaskSupervisor`;
- monitors the owner epoch;
- runs one worker;
- enforces an optional timeout;
- terminates the worker when the owner terminates;
- maps normal return, expected error, crash, timeout, and cancellation to one correlated private event;
- never serializes private references into public state.

Resource serialization remains in each owning FSM; the helper is not a generic domain effect runner.

## Phase 6 — dependencies and alarms

1. Add `NervesGate.Dependencies` as an atomic DeviceState subscriber.
2. Reconstruct dependency inputs from the initial snapshot, then project each relevant public event to private FSM events.
3. Remove lifecycle dependency derivation from DeviceState.
4. Make `NervesGate.Alarms.Runtime` another snapshot/event consumer.
5. Keep policy in subsystem `alarms.ex` files.
6. Ignore `:alarms` source events for signal recomputation.
7. Publish the complete active alarm state through the authenticated `:alarms` owner.
8. Remedies call lifecycle owners and never mutate alarm evidence directly.

## Phase 7 — configuration saga

1. Keep private accepted settings, candidates, credentials, change IDs, deadlines, and rollback data in `Gateway.Configuration`.
2. Convert persistence and subsystem work to transient states and correlated completion events.
3. Persist before reporting accepted public state.
4. Include serializable applied/failed change IDs in subsystem public status where Configuration needs restart-safe completion evidence.
5. Let Dependencies project matching public subsystem state into Configuration events.
6. On restart, hydrate files, inspect current public/runtime reality, and replay idempotent commands using the same change ID.

## Phase 8 — supervision and boot

1. Put stable runtime infrastructure before the restartable public-state subtree.
2. Under the actual `:rest_for_one` parent, place DeviceState before Dependencies, Alarms, publishers, Configuration, and replicas.
3. Verify by killing the real DeviceState process in an integration test.
4. Keep the one-time StartupGate boot decision outside repeated DeviceState reconstruction or guard it with boot-epoch state.

## Phase 9 — delete obsolete architecture

Delete:

- DeviceState operations/actions and `:broadcast`;
- `reduce/2` and `apply_operation` APIs;
- generic synchronous transition/state command hacks;
- direct runtime effects in `on_transition/4`;
- direct alarm reporting from FSMs;
- DeviceState dependency derivation;
- per-subsystem browser PubSub reload topics;
- replica event buffering;
- multi-process dashboard/commissioning model sampling;
- generic gateway effect abstractions superseded by owner runtime boundaries.

Compatibility aliases are not retained unless required by an external protocol.

## Phase 10 — final gates

Run:

```sh
mix format
mix test
mix credo --strict
mix dialyzer
mix nerves_gate.fsm_docs
mix docs
MIX_TARGET=x86_64 mix compile --warnings-as-errors
git diff --check
```

Also run standalone QEMU tests and the real supervision/hydration integration scenario. Regenerate lifecycle Mermaid documentation only after FSM definitions settle.
