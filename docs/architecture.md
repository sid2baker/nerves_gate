# Jido v3 architecture

NervesGate uses domain Jido Actions and Agents for commands and coordination,
ordinary OTP processes for infrastructure, and existing subsystem observations for
reads. There is one application command path, no central state/projection server,
no event-sourcing database and no AI dependency.

## Dependencies and compatibility

The immutable v3 source set in `mix.exs` / `mix.lock` is:

| Dependency | Pin |
| --- | --- |
| Jido (`3.0.0-beta.1`) | `agentjido/jido@90763478104f1edbf0afcfcf9444621c3f9755e8` |
| Jido Action (`3.0.0-beta.12`) | `agentjido/jido_action@8e9b3f7b268e175091b0eb3720bab3b8633d3c24` |
| Zoi | `mikehostetler/zoi@2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9` |
| Jido's internal Runic engine | `mikehostetler/runic@6b1c8c85d2d560a7ff5da6c3a417254c5d2b85b6` |
| Jido Signal / Alarmist / PropertyTable | locked `3.0.0-beta.4` / `0.4.2` / `0.3.4` |

**Approved exception:** current Jido v3 requires Runic internally even to execute
individual Actions. Its published dependency set failed Hex resolution for the
required Runic alpha versions. These compatible source pins resolve that without
forking the executor or introducing a second execution path. NervesGate has no
direct Runic calls, graphs or routing; the override is an internal dependency pin,
not an application API. Complete removal from the dependency graph is not claimed.

Reconnaissance inspected the actual v3 Action, AgentServer, Plugin, Signal,
Scheduler and sensor code, rather than the repositories' v2 `main` APIs. The
[release requirements](https://hex.pm/api/packages/jido/releases/3.0.0-beta.1) and
[pinned Action executor](https://github.com/agentjido/jido_action/blob/8e9b3f7b268e175091b0eb3720bab3b8633d3c24/lib/jido_exec.ex)
record the dependency constraint. Local tests and EC100 production compilation use
Elixir **1.20.4 / OTP 29.1**. Upstream Runic emits compiler warnings; application
compilation passes `--warnings-as-errors` without suppressions.

## Responsibilities and state ownership

| Owner | Authoritative state / responsibility |
| --- | --- |
| VintageNet | Applied Ethernet configuration, interfaces, addresses, routing and runtime observations |
| Tailscale | Daemon state, VPN identity, preferences, routes and enrollment |
| Network trial journal | Previous/requested application settings and the durable pending/confirmed decision |
| Network Agent | Normal-path trial policy: await manual confirmation, await readiness, auto-commit verified USB setup, or reject conflicts |
| Network Runtime | Effect preconditions/vetoes, journal writes, independent deadline, bounded hardware worker and recovery barrier |
| Remote Agent | Enrollment/operation admission and correlated outcomes; no identity/preferences mirror |
| Remote Runtime | One bounded daemon worker, cached subsystem reads and sanitized operation metadata |
| Alarmist | Derived connectivity conditions |
| Connectivity Agent | Bounded read-only recheck policy; never automatic disruptive recovery |
| PropertyTable | Existing subsystem properties plus ephemeral workflow/host-simulation observations |
| Device / Selectors | Stateless wire facade and pure on-demand interpretation, not a stored read model |
| LiveView | Drafts, presentation, lifecycle-bound subscriptions and command submission |

Requested settings are in a pending trial; applied settings and observations are
read through the adapter. A successful apply is not proof of Internet or equipment
reachability. Agents retain workflow metadata, not copies of hardware configuration.

```text
LiveView / IEx / future interface
           │ Device.dispatch
           ▼
     Public domain API
           │ request Signal
           ▼
  Jido AgentServer → Action + live Plugin admission
           │ candidate state + typed post-commit directive
           ▼
    Infrastructure Runtime → bounded owned worker → adapter
           │                                      │
           │ meaningful facts                     ▼
           └─────────────────────── VintageNet / Tailscale
                                             │ existing properties
                                             ▼
                   PropertyTable ───────────► LiveView → pure selectors
                        │
                        ▼
                     Alarmist → Connectivity input → Jido Agent
                                                          │
                                                  read-only recheck
```

Pure draft validation executes a Jido Action directly with `Jido.Exec.run/4` and
does not require a running agent or a daemon. See [action-api.md](action-api.md)
for the eight public commands, result shape and domain-specific revision checks.

## Supervision and execution lifecycle

Application `rest_for_one` order is PubSub, Registry, workflow PropertyTable,
managed `NervesGate.Jido`, host simulators (host only), Network, Remote,
Connectivity, then Endpoint. Dependencies provide their own supervised applications
(including Alarmist and, on firmware, VintageNet/Tailscale).

Each Network/Remote domain is a `rest_for_one` supervisor: runtime first, permanent
Jido AgentServer second. Runtime restart kills its linked worker and starts a fresh
agent after recovery. Agent-only restart leaves the runtime's authoritative safety
state intact; active work is interrupted/reconciled through an owner monitor.
Admission reads that state afresh, and every effect rechecks it at the serialized
boundary. A stale agent state or duplicate fact cannot authorize unsafe work.

Actions use Zoi input schemas and return complete candidate state with typed
Directives. Native Plugin admission supplies live context; Plugin dispatch performs
effects after AgentServer commits. I/O runs in bounded linked workers outside
agent turns and runtime mailboxes. Private command reply aliases handle completion;
timeout is explicitly an unknown outcome, not cancellation or permission to replay.
The native postponed-signal queue is bounded to 32; fact loss must be reconcilable.
Network Plugin dispatch returns after effect submission, not worker completion.
This frees the agent to process the applied/readiness facts that determine the next
step. The runtime retains the private command reply context until its required
acknowledgment boundary; no caller handle enters agent state or the journal.

Connectivity uses a native Plugin-owned input process and the Jido Scheduler
plugin. Source inspection found no built-in PropertyTable sensor. Its fixed input
process is therefore a small subscription adapter, not a parallel sensor framework.
AgentServer runs under the managed Jido instance: the pinned beta's standalone path
can orphan Plugin children after abrupt owner death. The supported instance-backed
path preserves ownership; tests verify sensor, scheduler and linked probe teardown.

## Network workflow policy

`Network.Actions.Advance` replaces the metadata-only Observe Action. It evaluates
fresh Plugin admission rather than trusting a queued event's phase:

| Current trial | Agent decision |
| --- | --- |
| Applying, committing or recovering | Observe progress; issue no overlapping effect |
| Manual, applied | Await explicit confirmation |
| First verified USB setup, ready | Request `auto_confirm` |
| First verified USB setup, conflicting addresses | Request `auto_cancel` |
| First verified USB setup, not ready | Request `await` to acknowledge application; then wait for readiness |

Every automatic effect is rejected on a manual trial. Runtime execution rechecks
ID, deadline, worker exclusivity and the requested effect's current preconditions.
If readiness changes between admission and execution, it rejects the stale decision
rather than choosing another normal-path operation itself. Apply failures, expiry,
agent death and interrupted persistence still trigger unconditional safety recovery.

Readiness changes send a private `network.workflow.reconcile` request; while a
trial is pending, a one-second reconciliation interval repairs missed delivery.
Requests do not change the form revision or become public facts. Ordinary facts
are correlated/deduplicated by runtime incarnation, trial ID and sequence.
Reconciliation deliberately permits the same sequence but always reads fresh
admission. Raw property changes are still coalesced before interpretation.

The independent runtime cannot auto-save merely because it observes readiness:
an agent decision is required. A suspended agent cannot prevent deadline rollback.
There is one normal-path coordinator and a separate safety mechanism, not two
competing workflow state machines.

## Durable network trials

The user confirmation window remains **60 seconds**. Only first setup through
server-verified USB auto-saves, within its **15-second** internal bound. USB never
joins a LAN bridge or transaction. Readiness requires the intended topology and
manual addresses, not cable/lease/Internet availability. Observed subnet conflicts
block confirmation. IDs, deadlines, revisions and conflicting work are rechecked.

`AtomicFile` uses mode 0600, exclusive temporary creation, file sync, rename and
directory sync. `TrialStore` keeps a versioned journal next to the settings file:

- Prepare: sync previous settings → sync pending journal → allow hardware apply.
- Confirm: sync requested settings → sync confirmed marker (**commit point**) →
  cleanup. A crash before the marker restores previous settings.
- Recover: pending restores previous; confirmed finishes requested. Apply that
  decision to disk and hardware; delete the journal only after both succeed.
- Uncertain marker writes are re-read, never blindly rolled back. Failed cleanup
  blocks new work but does not undo a confirmed decision. Corrupt journals fail
  closed; valid journals can recover a damaged primary config file.

An independent monotonic watchdog stops and joins the current worker before
recovery. Reboot never relies on the journal's informational wall-clock expiry.
Recovery is idempotent and retries while admission remains blocked. VintageNet's
configuration/settlement barrier accounts for subsystem work outliving a caller.
Neither transient signals, agent memory nor Jido timers are safety authorities.
See [networking.md](networking.md) for operational recovery and unchanged port rules.

## Remote and connectivity policies

Remote accepts one bounded asynchronous daemon operation at a time. Acceptance and
completion are different outcomes. Crashes/timeouts stop the worker and observe the
daemon; they never replay a mutation. Connect/rename patch hostname and
`accept_dns: false`, preserving omitted preferences. Startup never rewrites an
existing profile. Identity stays under `/data/tailscale_ex`.

The login URL Action requests a private cached query. Its directive replies only
to the requesting caller. No URL enters Action results, agent state, public facts
or subscribed properties. Hostname inputs and official HTTPS login hosts are
validated; health URLs and raw errors are redacted from public observations.

Alarmist derives `InternetUnavailable` from InternetExpected, InternetOnline and
ObservationUnavailable. Only the assigned Internet interface counts; an
unconfigured or equipment-only gateway does not require Internet. Conditions
outlive agent/input restarts. Subscribe before reading cached condition state.

Connectivity performs at most three bounded **read-only** probes per outage per
agent lifetime. Correlation rejects stale timers/completions. Five-second input
reconciliation repairs lost facts/timers; replacing that input retains the remaining
budget, while restarting the whole agent starts a new bounded budget. Cancellation
joins the worker before another runs. There are no NIC changes, DHCP restarts,
VPN reconnects, logouts, DNS resets or enrollment effects in this policy.

## Signal and observation contract

Request types are the public command names. Facts contain workflow metadata, not
raw PropertyTable changes. `Jido.Signal` supplies envelope ID, type, source and time.
Action schemas validate consumed payloads; these tables describe the domain data:

| Facts | Payload |
| --- | --- |
| `network.configuration.{proposed,applied,failed}`, `network.trial.{confirmed,expired,rolled_back}`, `network.runtime.reconciled` | `trial_id`: string or nil; `phase`: `idle`, `applying`, `pending`, `confirming` or `recovering`; `sequence`: runtime-local integer |
| `remote.connection.{requested,established,lost}`, `remote.operation.{started,completed,failed}`, `remote.enrollment.failed`, `remote.daemon.{available,unavailable}` | `operation_id`: string or nil; `phase`: `idle` or `running`; `sequence`: runtime-local integer |
| `connectivity.{lost,restored}` | `revision`: Alarmist condition timestamp/integer |
| `connectivity.recheck.completed` | `outage`: condition revision; `attempt`: integer 1–3 |

Network/Remote sources include runtime incarnation; Connectivity source identifies
its scope. Sequence ordering is local, never a global event order. Facts are sent
to domain agents and public Phoenix PubSub event topics as applicable. Delivery is
**best effort, non-durable, without exactly-once guarantees**. Subscribers re-read
on startup/reconnect. Lost lifecycle facts cannot defeat runtime admission or
network recovery. Private reconciliation requests are not a public event log.

Firmware subscribes to existing VintageNet/Tailscale properties. The application
table adds workflow metadata only; host adapters publish simulated observations
there. LiveViews subscribe before reading, coalesce notifications for 20 ms and
re-run selectors instead of applying queued snapshots. Lifecycle cleanup removes
subscriptions; panels reuse parent assigns. Domain polling rebinds subscriptions
and reconciles state; raw property bursts do not flood AgentServer queues.

Future packet observers can use a separate bounded ingestion pipeline, normalized
PropertyTable namespace and significant discovery Signals for a DiscoveryAgent.
Backpressure belongs at ingestion, outside command turns; raw packets never belong
in agent state. No packet capture or inventory implementation is included.

## Migration map and removed components

Baseline: `6ddc75d`. Existing UI layout, wire commands, host simulation, persisted
config formats and exposure policy are retained.

| Old module / mechanism | Replacement |
| --- | --- |
| `Device.Workflow` Runic graph | Domain Jido routes and Actions; **deleted** |
| `Device.Actions` centralized catalog/router | Domain Action schemas/routes; presentation-only selector availability; **deleted** |
| `Device.Projection` | Pure `Device.Selectors`; old module **deleted** |
| Device GenServer and cached snapshot bus | Stateless Device facade, live domain reads and direct subscriptions |
| Monolithic Network GenServer | Network supervisor, Agent/Actions/Plugin, safety Runtime, TrialStore and Recovery |
| Monolithic Remote GenServer | Remote supervisor, Agent/Actions/Plugin and asynchronous Runtime |
| Network/Remote snapshot broadcasts | PropertyTable workflow metadata and significant Jido facts |
| Component-owned Device subscriptions | Parent LiveView observation bindings and presentational panels |
| Direct Runic integration-test bootstrap / pristine-fact unit test | Jido bootstrap, native routing/lifecycle/effect and recovery tests |

`.reach.exs` rejects the deleted modules, direct application Runic calls, web
access to agent/runtime internals or hardware mutation, and I/O from pure Actions
and selectors. No compatibility Runic execution path remains.

## Verification and limitations

- Native v3 schema/routing/admission/directive and Alarmist probes passed on the
  pinned toolchain. Unit/LiveView coverage includes conflicts, revisions, duplicate
  facts, process crashes, reboot recovery, partial persistence and subscription cleanup.
  Network workflow tests additionally prove agent-owned auto-save, dropped-readiness
  reconciliation, stale-decision vetoes and rollback with the agent suspended.
- Final `mix deps.get` and `mix ci` passed: 164 tests, strict Credo, Dialyzer (no
  skips), zero-clone duplication and architecture/smell checks.
- Final isolated Linux LAN run passed all 14 checkpoints, retaining real DHCP,
  bridge hotplug, rollback, restart, port reversal, USB and HTTP assertions.
- Final isolated real Tailscale 1.104.1 check passed; cached reads, async writes,
  DNS policy and route preservation remain covered.
- Real host-browser checks passed for Network apply/cancel/restoration and
  simulated Tailscale connect/rename. Reload confirmed restored settings and the
  new name. Gateway, Network, trial and Tailscale pages had zero axe WCAG2 A/AA
  violations; the mobile Tailscale page had no horizontal overflow or JS errors.
- EC100 production firmware built and passed `fwup --verify`. Artifact inspection
  verified the v3 dependencies, absence of AI/development tooling, recovery SSH
  key, startup guard/Heart handshake and unchanged ARM tailscaled checksum.
  No firmware was flashed; no on-device boot, power-loss or physical USB/cable
  test is claimed for this rewrite.

Jido v3 is beta and includes upstream compiler warnings through its internal
Runic dependency. The independently reproduced OTP 29/MuonTrap `:epipe` race
caused earlier LAN integration failures; a successful final run does not fix it.
Disk fault tests cannot prove storage hardware's power-loss behavior. Jido facts
are not durable; domain recovery and conservative reconciliation are intentional.
The UI remains unauthenticated for trusted networks; no security expansion or
new hardware capability is implied by this migration.
