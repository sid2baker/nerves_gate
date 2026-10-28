# Workbench operations: single-cutover refactor

**Status:** source cutover implemented; `mix check` and `git diff --check` pass.
Real distribution reconnect/admission tests pass. QEMU acceptance remains pending
an explicitly coordinated user-owned session restart and authorized bench run.
JSON observation output and local artifact-baseline preflight are deferred.
Retain this plan until acceptance; current usage is documented in
[`docs/development.md`](docs/development.md).

## Goal

Make the correct operation obvious to humans and agents, and make the wrong path
fail before effects. Refactor the CLI, session attachment, Workbench jobs and their
UI consumers together in one implementation branch and one coordinated cutover.
No compatibility aliases, parallel command facades or incremental legacy mode.
Internally slice implementation commits by invariant so regressions are bisectable;
one coordinated runtime cutover does not require one monolithic commit. Each slice
must have focused tests, without introducing a mixed-version runtime mode.

This is a plan, not authorization to restart sessions, reset devices, change host
networking, upload firmware, publish, commit or push.

## Problems grounded in the current implementation

- `Workbench.Session.call/4` reads session metadata and calls a node, but does not
  itself verify the remote checkout root and session ID. Pi attachment has stronger
  requirements than the CLI. Both clients need the same session identity contract.
- `Workbench.CLI` mixes argument parsing, workflow policy, subscriptions and waiting.
  Plugin installation has different admission paths in CLI and Jobs; CLI packages
  before calling Runner, while Jobs distinguishes physical and simulated targets.
- `mix test.qemu` combines testing, lifecycle management and disposable CI startup.
  A command named test can erase disks; ordinary runs can implicitly choose the
  first simulated device.
- Loaded SDK metadata can disagree with the checkout and block an operation late.
- Immutable plugin conflicts are caught during firmware review, but diagnostics do
  not help enough during image preparation. Version bumps were missed in practice.
- Useful inspection and job observation require knowing internal module names.
- The documentation is good but operational choices are scattered across commands,
  prose, project instructions and executable skills.

## Target boundaries

Keep the existing deep owners, and remove duplicated policy rather than wrapping it.

| Owner | Responsibility |
| --- | --- |
| `Workbench.Session` | Session discovery, checkout/identity verification, bounded session transport and shutdown handshake |
| `Workbench.Gateways` | Sole verified gateway directory; explicit target resolution |
| `Workbench.DeviceInspection` | Bounded sanitized gateway reads |
| `Workbench.Jobs` | Serialized host/device maintenance admission, review consumption, progress and terminal outcomes |
| `Scenarios.Runner` | Scenario reservations, owned-QEMU lifecycle/fault admission and shutdown exclusion |
| Build/plugin/update modules | Their actual build, packaging, transfer, identity and transport policies |
| Mix tasks and LiveViews | Parse/render, invoke owners, observe results; no alternative workflow implementations |

Jobs and Runner remain separate: they protect different resources. Keep their
existing reservation relationship through worker exit. Do not introduce a generic
operations registry, dispatcher, global error catalogue or new supervisor per API.

## Final command surface

Keep the established standalone commands: `setup`, `firmware`, `plugin.new`,
`plugin.test`, `plugin.package`, `test`, `test.sdk`, `check`, `ci`, `format`, and release
commands. Standalone builds/tests do not start or require a Workbench session.
Keep `dev`, `dev.status`, `dev.stop`, `dev.network`, and `firmware.update`.

Replace ambiguous session-facing commands in the same cutover:

| Command | Contract |
| --- | --- |
| `mix dev.doctor` | Read-only local/session compatibility report; works when no session is running |
| `mix gateway.list` | List the verified directory, distinguishing physical and owned QEMU targets |
| `mix gateway.inspect TARGET` | Identity, health, plugins, hardware and storage summary; sanitized, read-only |
| `mix gateway.logs TARGET` | Bounded sanitized log snapshot; do not imply a streaming subscription |
| `mix simulator.start/stop/reset` | Explicit owned-QEMU lifecycle; reset requires explicit destructive confirmation |
| `mix scenario.list` | Catalogue with requirements and target kind; no device operation |
| `mix scenario.run ID --device TARGET` | Explicit case and target through Runner; physical cases through Jobs' existing physical admission |
| `mix scenario.ci ID` | Explicit disposable QEMU bench; never attaches controls to physical devices |
| `mix plugin.install PATH --device TARGET` | One Jobs-owned workflow; reviewed confirmation for physical transfer |
| `mix dev.job [ID]` | Read-only current/recent job state and bounded progress |

Remove `test.qemu`, including its `--lifecycle` and `--ci` modes, after updating all
callers. No old aliases. An explicit `all` selector may run the QEMU catalogue, but
must not include physical procedures. Never select the first device implicitly.

Use `mix help` for complete flags and examples. JSON observation output is optional
follow-up work, not a cutover requirement. If added, document its bounded schema
and never serialize raw internal state. Keep the command implementations thin without adding mirrored named-function
facades merely to rename owner calls.

## Implementation sequence — one delivery, not staged compatibility

### 1. Establish the session contract

- Add a remote handshake exposing root, session ID, protocol revision and loaded
  compatibility inputs. Canonicalize checkout paths consistently on both ends.
- Verify the locked metadata against the handshake before session operations.
  Recheck the expected session ID inside admission for writes, closing the
  discover/dispatch race. A replaced session must reject the old request.
- Define compatibility from loaded SDK/platform app versions, the session protocol
  revision and a small explicit manifest of protocol-defining modules/artifacts.
  Enumerate that manifest before implementation and test its coverage. Compare the
  running session's captured input digests with the candidate build's corresponding
  inputs. A matching version alone must not conceal changed protocol code.
  Do not infer semantic relevance, scan all source files, construct a dependency
  graph or invent another build system. Unrelated source/docs changes must not
  invalidate the session. This is a protocol-compatibility check, not a promise
  that every loaded module matches the checkout.
- Preserve read-only diagnostics when mutation is blocked by stale code.
- Consolidate CLI and Pi attachment on this contract. Update repository-provided
  skill resources; report installed bridge retargeting limitations explicitly.
- Never start another session or retry a write when attachment fails.

### 2. Make admission and outcomes consistent

- Route UI and CLI session operations through the same named Jobs/Runner functions.
  Remove alternative install/build/control paths that bypass their admission.
- Keep standalone host build/test/package operations independent of session Jobs;
  protect shared output paths against concurrent standalone/session builders with
  explicit build-resource exclusion, not a requirement to launch Workbench.
- Jobs and Runner each issue and retain their own session-scoped operation IDs as
  part of admission. Keep the owner explicit in references; there is no shared
  `Operations` module, ID service or operation store. Two small implementations
  are preferable to conflating their resource semantics. Report acceptance
  separately from completion; callers can inspect a known ID after a wait timeout.
  If admission's reply itself is lost and the caller has no ID, report uncertain
  admission and inspect the owner's state; never resubmit to obtain an ID.
- Expose distinct rejected, running, succeeded, failed and uncertain outcomes, with
  effect certainty and the next safe observation. Do not infer "no effects" from
  an exception. A client wait timeout does not cancel the worker.
- Preserve unknown-outcome control blocks and checked cleanup. No generic retry,
  force-unblock button or cross-session replay of requests/review tokens.
- Retain bounded session-local terminal job history for inspection; no database or
  durable operation journal. After session loss, report loss of knowledge honestly.
- Keep subscriptions owned by the observing PID; subscribe before snapshot and
  recover explicitly after owner/session loss.

### 3. Move actionable checks earlier

- `dev.doctor` reports checkout/session identity, source-versus-loaded compatibility,
  prerequisite availability, owned network preparation and simulator state. It
  observes only: no sudo, builds, resets, connection repair or auto-restart.
- Before admission, each operation's existing owner checks its actual requirements:
  session compatibility, target kind, reservations, storage, trust and permissions.
  Do not build a universal preflight framework or duplicate owner validation.
- Optional follow-up: packaging/builds compare new artifact digests against
  available prior local manifests and flag same-name/version conflicts. Missing
  baselines mean unknown, not compatible. Keep build inputs deterministic to avoid
  meaningless conflicts. Do not build artifact-history infrastructure for this
  refactor; improved authoritative review diagnostics are sufficient for cutover.
- Review against the selected gateway remains authoritative: source-only builds
  cannot prove compatibility with every deployed gateway. Revalidate exact image,
  gateway identity, artifact compatibility and SSH trust at the existing safe
  boundaries. Never weaken review because local preflight passed.
- Diagnostics name the conflicting plugin/version and prescribed action. Never
  auto-bump, import old metadata, change selections or erase saved configuration.

### 4. Replace the CLI and update UI consumers

- Implement the command table, strict argument validation, explicit target selection,
  consistent nonzero failure exits and help examples.
- Split the large CLI module by real workflow ownership. Share only transport,
  observation and presentation mechanics that have multiple actual consumers.
- Give UI and CLI the same preflight reasons, job IDs and terminal distinctions.
  UI availability is explanatory, never the admission authority.
- Keep firmware review single-use, image-bound and target-bound; preserve interactive
  confirmation and exact-SHA noninteractive approval. Plugin/factory confirmation
  retain their own domain-specific contracts.
- Keep Workbench localhost-only and gateway views read-only except for the existing
  explicit maintenance workflows. No HTTP control API or general remote command proxy.

### 5. Remove obsolete paths and update every consumer

- Update tasks, LiveViews, tests, CI workflows, executable skills, `AGENTS.md` and docs
  together. Search structurally for replaced Elixir calls; use AST/LSP refactors.
- Make `docs/development.md` the canonical operational matrix: intent, invocation,
  required session, effects, confirmation, completion and recovery.
- Document the RPC rule: prefer a supported workflow; attach to the verified session
  for inspection; scenario code uses its bounded RPC helper. Raw `:erpc` belongs in
  the owning transport code, not agent snippets or UI code.
- Preserve actual-PID ownership of SDK subscriptions, leases and resource handles.
  Workbench is not an SDK owner proxy.
- Delete replaced APIs and helpers. Do not keep aliases, fallback node discovery,
  alternate connection loops or arbitrary module/function command dispatch.

## Validation and acceptance

Host tests must cover:

- Absent, stale, foreign-checkout and replaced sessions; matching version with
  changed compatibility inputs; actionable diagnosis without mutation.
- Wrong/ambiguous target and unsupported physical scenario rejected before effects.
- CLI/UI entry points sharing admission; concurrent job/lifecycle/shutdown exclusion.
- One-time target/image-bound confirmations and expired/stale review rejection.
- Lost replies, client timeouts and worker exit: no automatic retries or premature
  release of reservations; unknown outcomes remain blocked.
- Authoritative artifact-conflict diagnostics and serialized shared build outputs;
  missing-baseline distinctions if optional local artifact preflight is implemented.
- Bounded, secret-free observations and command help/exit contracts; JSON schema
  tests only if that optional output is implemented.

Use pure policies and existing host tests for these contracts. Do not add a mock SDK,
virtual hardware backend or a second implementation of gateway behavior.

Run root `mix check` and `git diff --check`. Extend real QEMU scenarios for the new
CLI/session path, reconnect, plugin installation and uncertain-outcome handling.
Run them only on an explicitly authorized bench after coordinated session restart
and any separately approved disposable-disk reset. Rebuild guests where required.
Physical firmware upload, factory provisioning and networking changes remain
separately authorized; no physical tests are implied by this refactor.

Completion requires:

1. Every routine operator intent maps to one documented workflow.
2. Old task/API entry points and all repository consumers are removed or updated.
3. Stale sessions and immutable-artifact conflicts have actionable diagnostics.
4. CLI and UI share backend admission and effect-aware outcomes.
5. Host results, artifact builds, QEMU results and unperformed physical validation
   are reported separately. A blocked runtime check is not reported as passed.

## Delivery slices and scope guard

Implement and validate in this order, as internally reviewable commits:

1. Session handshake, explicit compatibility manifest and admission identity fence.
2. Jobs/Runner-owned IDs, effect-aware outcomes and reservation-lifetime guarantees.
3. Unified install/maintenance admission and shared build-output exclusion.
4. Intent-based CLI, explicit target selection and corresponding UI consumers.
5. Minimal doctor/inspection commands, actionable review errors, consumer cleanup
   and canonical documentation.

Commits are implementation checkpoints, not supported deployment combinations.
Run the complete acceptance gate on the final tree. No commits or pushes are
implicitly authorized by this plan.

The non-negotiable critical path is session verification, explicit targets,
Jobs/Runner admission and honest uncertain outcomes. If scope expands, defer JSON
output and local artifact-baseline preflight explicitly; do not weaken these
invariants or add temporary compatibility paths. Record deferred work in the
completion report rather than claiming the optional features were delivered.

## Cutover and recovery

Deliver one coherent source change with no mixed old/new runtime contract. Ask the
operator to stop the old idle Workbench and start the new one. Preserve session
locks, guest disks, saved gateway settings, plugin metadata and configuration terms.
Do not reset a bench merely to accommodate a host protocol change.

If cutover fails, stop effects and diagnose. Source rollback is permissible only
with coordinated session replacement; it is not permission to downgrade device
state, remove locks or replay uncertain operations. Remove this plan after its
accepted implementation and keep only documentation of the current system.

## Explicitly outside scope

- Gateway business-domain redesign, automation or additional Modbus features.
- Automatic migrations, settings resets, plugin selection or firmware deployment.
- Generic operation frameworks, mirrored command APIs, databases and global errors.
- Pi extension internals outside repository ownership; file/report tooling blockers
  rather than silently bypassing the verified attachment path.
- Existing unrelated changes: preserve the uncommitted Tailnet 0.1.6 version bump
  and changelog without folding them into this refactor by accident.
