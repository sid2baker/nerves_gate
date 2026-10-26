# Application lifecycle hardening plan

## Implementation status

Source implementation now includes the artifact/metadata/owner/loader cutover,
responsive serialized Apps workers, generation-fenced SDKBackend/Buses/Network,
current-only blocked metadata handling and managed scenario fixtures. Same-version
replacement is removed; workbench and scenario deadlines match the lifecycle budget.
Docs and changelogs describe the breaking contract and rollback limits.

Host checks and target builds are tracked separately from runtime qualification.
Managed fixture archives have been built and validated without loading their modules
into the host. The QEMU lifecycle/SDK scenarios have **not** been executed: the user
explicitly chose to leave runtime qualification pending. No bench/device lifecycle,
metadata migration or publication was performed during implementation.

Latest checks: root `mix check` (168 root, 133 firmware, 12 SDK and 2 starter
checks/tests passed, plus the nested generated-app tests), focused firmware
host/test Dialyzer (zero errors),
x86_64 dev and EC100 dev/prod firmware builds, native musl-loader verification,
and real independent fixture package builds.

The acceptance scenarios cover real preload/start/health/commit faults, immutable
version conflicts, archive/content tampering, busy-code cleanup, PID/generation
revocation, in-flight lease cleanup, SD detach/reattach, interruption during health
verification and repeated cold lifecycle/restart. Unit tests
cover metadata rejection, artifact integrity/namespace admission, partial preload,
actual OTP membership, unavailable route-owner journal retention and retained
blocked network cleanup. Unexecuted fault scenarios
are not evidence that runtime guarantees have been proven. Further qualification
must exercise the fault paths on the authorized disposable bench, including
controller/storage interruption across additional lifecycle phases and real tailnet
route-withdrawal failure; do not mark this plan qualified yet.

## Goal and delivery

Improve the current application manager in one coordinated implementation: immutable
verified artifacts, explicit cold-activation phases, generation-fenced SDK resources,
reliable cleanup/rollback and lifecycle qualification.

The implementation order below is a dependency order within that single change,
not permission to ship incomplete phases. This document authorizes no code change,
deployment, device reset, metadata migration, commit, push or publication.

## Pre-cutover baseline and addressed gaps

- `firmware/lib/nerves_gate/apps.ex` already serializes commands, starts private OTP
  applications, runs a five-second health check, commits selection after success,
  and reuses `halt/unload` for stop and rollback. Preserve those semantics rather
  than build a parallel lifecycle engine.
- Installed metadata stores enabled/active/previous versions, but no artifact
  digest. `read_package/2` reparses extracted directories without an independently
  recorded integrity identity.
- Installation can delete/replace an unselected version directory. Removing that
  replacement path is part of making all installed artifacts immutable.
- Startup adds code paths and loads `.app` specifications, but does not explicitly
  load every verified module before OTP startup. Cleanup currently ignores stop,
  unload and purge failures.
- Lifecycle effects run inside the Apps GenServer. Adding synchronous SDK-to-Apps
  ownership queries would deadlock startup; long operations must not block its
  admission/status/ownership control plane.
- SDK events, buses and network leases already belong to actual calling PIDs and
  opaque references. They are not currently app-owned. Add generation fencing
  without replacing that ownership.
- Extend the real `Scenarios.Cases.Apps` and SDK scenarios. They already cover SD
  admission, generated packages, upgrade failure, rollback, restart and removal.

## Design decisions

### Artifact identity and storage

Introduce `NervesGate.Apps.Artifact`, a validated immutable description containing
app, version, archive SHA-256, installed root, private application specifications,
module identities, code paths and the expected content manifest. Do not keep the
entire package byte map in long-lived controller state.

- Artifact identity is `{app, version, sha256}`. Generation is not an artifact field.
- Install through an exclusively created staging directory, then rename into an
  exclusively owned final artifact directory under the application SD root.
- Store the original archive and extracted content separately inside that directory;
  point OTP paths only at the extracted content. Bind both to the digest recorded
  in controller-owned installed-version metadata.
- Verify the retained archive SHA and the complete extracted file set before each
  activation. Compare file contents, paths and file types against the verified
  archive, including `.app`, BEAM, `priv` and native files. Reject missing/extra
  files and symlinks; preserve required executable permissions.
- Never remove an existing destination to make installation succeed. Reject a
  different digest for an already registered app/version. Identical existing
  artifacts are not overwritten; `install_new` still rejects an existing app.
- Report unregistered/conflicting directories; do not adopt or erase them
  automatically. Cleanup may remove only staging created by the current operation.
- App data remains separate, writable and preserved by stop, rollback and uninstall.
  Read-only artifact permissions are an accidental-write guard, not a sandbox.

### Activation identity and controller ownership

Keep a separate private activation record: artifact, generation, operation identity,
phase, acquired paths/specs/modules, started private applications and owned workers.

- Use a fresh controller epoch plus an increasing activation sequence. Allocate a
  generation for every activation attempt, including failed attempts and rollback.
  Never reuse the failed generation when restoring the previous artifact.
- Persist the selected artifact identity and committed generation/sequence for
  diagnostics. Restored apps always receive a fresh runtime generation; persisted
  generations are never restored as live resource authority.
- `Apps` retains one admission slot and owns metadata/selection. Run bounded loader
  effects in an owned, monitored worker, keeping status/admission responsive.
- Record enough prepared ownership and acquisition progress to reconcile partial
  activation after a worker fails. Accept completion only for the current operation
  and generation. Do not let a late worker commit a different selection.
- A timeout does not mean an OTP start, stop or external effect was cancelled.
  Keep uncertain operations blocked until their worker/runtime state is reconciled.
  Align domain, workbench and scenario RPC deadlines with the lifecycle budget.

### Stateful SDK access and generation fencing

**Intentional contract choice:** stateful SDK operations require a managed
application activation. Read-only SDK queries remain available outside managed
apps. Raw IEx/RPC maintenance uses administrative domain APIs, not an invented
unmanaged generation. Update SDK scenarios to execute stateful calls inside real
managed fixture applications.

- Provide a small internal owner-resolution/read interface under `Apps`, backed by
  controller-owned protected ETS. Do not add a separate generic registry service.
- Publish pending private-app-to-generation bindings before OTP startup, allowing
  legitimate startup callbacks to acquire resources without calling the busy Apps
  server. Resolve the actual caller using OTP application membership, including
  bundled private dependencies; never trust a caller-supplied app name or module.
- Check ownership when the domain handles a request, not just in the SDK wrapper.
  Store `{pid, app, generation, ref}` where applicable. PID monitoring and reference
  matching remain mandatory; no Task or SDKBackend process becomes a proxy owner.
- Fence new claims, writes, advertisements and event delivery when a generation is
  quiescing/revoked. Preserve narrowly scoped release/cleanup during quiescing.
- Add explicit generation-drain operations to SDKBackend, Buses and Network. Network
  must still withdraw its owned route before removing addressing and retain its
  cleanup journal and fail-closed treatment of uncertain outcomes.
- Account for in-flight domain workers: revocation prevents stale completion from
  granting authority to a new activation, but does not undo an admitted write.
  Do not activate another generation until required cleanup is confirmed.
- On Apps/controller restart, invalidate the previous epoch and reconcile known
  managed runtime/code/resources before restoring enabled selections. Missing
  ownership state must not turn old callers into unmanaged authorized callers.
- Already delivered messages cannot be recalled. OTP application stop terminates
  normal application process groups, including ordinarily unlinked children.
  Tests must distinguish queued consumer messages from new post-revocation delivery.
- Arbitrary externally supervised tasks or deliberate group-leader/ownership
  manipulation are not supported containment guarantees. Apps remain trusted
  same-BEAM code, not a sandbox.

### Loader phases and shared cleanup

Introduce one deep `NervesGate.Apps.Loader` owning code-server/OTP lifecycle effects.
Use named internal steps, not six new public administrative APIs or a generic
workflow dispatcher. Keep existing public command/result shapes where possible.

1. **Prepare:** verify archive/content hashes, storage/card identity, paths, SDK and
   platform requirements, private dependency ownership, BEAM identities and module
   collisions. Keep reservations for every installed app, including stopped or
   unreadable artifacts; corruption must not release their namespaces. Validate
   the candidate before stopping working code.
2. **Quiesce previous activation:** after preparation succeeds, stop new SDK
   admissions for its generation, stop its private OTP applications and drain its
   resources. This remains a cold upgrade: old and new modules do not run together.
3. **Activate:** add only verified owned paths, load verified `.app` specs and load
   every candidate module from verified bytes with its expected identity/path.
   Do not accept `:code.ensure_loaded/1` alone: it can return previously loaded code.
4. **Start:** call `Application.ensure_all_started/1`, recording private apps started
   and any partial failure. Never adopt or stop shared platform dependencies.
5. **Verify:** run the bounded health check against this generation. Health checks
   inspect the app's own APIs; their platform-supervised Task must not borrow SDK
   resource ownership on the app's behalf.
6. **Commit:** recheck storage/operation identity and atomically persist exact
   active/previous artifact references, enabled intent and committed generation.
   Persistence failure is activation failure, not success with a warning.
7. **Rollback:** use the same unload path for the failed candidate, then re-prepare
   and verify the exact previous artifact before activating it with a new generation.
   Restore only if it was previously running. Report rollback failure distinctly.

One `Loader.unload/1` path handles normal stop, partial-start failure, upgrade and
rollback cleanup: revoke/drain generation resources, stop private applications in
reverse dependency order, unload owned specs/modules and remove only acquired
paths. Return cleanup outcomes to the controller; never silently ignore failures.

Use safe code deletion/purge checks. If executing code, a NIF or an uncertain
resource effect prevents cleanup, leave a visible blocked state and preserve
admission/ownership information. Do not force-purge unrelated processes or start
another generation over an unresolved one. Preserve today's rule that explicit
stop persists disabled intent before stopping; persistence failure must not
silently re-enable an app after reboot.

Preloading can execute `@on_load` and NIF initialization. It is not an effect-free
validation step. Stateful SDK calls without a managed OTP context are rejected;
arbitrary user-code side effects and application data migrations cannot be undone
by loader rollback and must not be advertised as covered guarantees.

## Metadata cutover and public surfaces

- Introduce one explicit, validated metadata schema containing the artifact catalog,
  exact active/previous references, enabled intent and committed generation data.
  Preserve atomic synced writes; reject malformed or unsupported records.
- No old metadata reader, digest backfill, automatic migration or layout alias.
  Unsupported existing metadata must leave app management blocked with an actionable
  error while gateway management remains available, not trigger a reboot loop.
  Do not clear metadata, start unknown code or make storage formatting appear safe.
- Existing installations need a separately authorized external upgrade/reinstall
  procedure. Preserve app data and saved state; never reset them to pass checks.
- Update `Apps.list/0`, workbench/CLI consumers and install verification only as
  needed for safe artifact identity and blocked-state reporting. Keep opaque
  generation authority, references, PIDs and private paths out of projections/logs.
- Update application/SDK documentation, changelogs and ownership guidance alongside
  implementation. Keep independent projects; no new package format, plugin system,
  hot upgrade or data-rollback framework. No release/publication in this change.

## Single-pass implementation order

1. Add regression cases around the existing lifecycle and package contracts.
2. Implement artifact identity, immutable staging/storage, content verification and
   the new metadata schema together; remove the replace-directory installation path.
3. Extract the loader and track partial effects; move lifecycle work off the Apps
   control plane while retaining one admission slot and explicit deadlines.
4. Add verified module loading, bounded startup/verification, commit failure handling
   and one unload/rollback path.
5. Integrate generation resolution, revocation and resource draining in SDKBackend,
   Buses and Network. Update managed SDK fixtures and all affected callers/docs.
6. Qualify the entire change as one cutover. Do not declare completion with hashing,
   cleanup, resource fencing or failure-path tests deferred to another release.

## Acceptance tests

Extend `lib/scenarios/cases/apps.ex` and SDK scenarios on owned disposable QEMU,
with pure metadata/artifact/transition checks under `firmware/test/unit/` and package
checks under `sdk/test/`. Do not introduce a fake hardware/SDK backend suite.

- Wrong BEAM identity, path traversal/symlink, incompatible dependency and loaded
  module collision fail before stopping the working activation.
- A valid package containing a module that fails actual loading/`@on_load` never
  starts OTP application code; partial specs, modules and paths are cleaned up.
- Archive/content tampering, extra files and same-version/different-digest installs
  fail without overwriting a registered artifact or erasing unrelated files/data.
- Failed startup, health failure/timeout and metadata commit failure restore the
  exact previous artifact when cleanup is confirmed; a stopped previous selection
  remains stopped.
- Failed cleanup, missing/corrupt rollback artifact and late worker completion
  produce blocked/rollback-failed results, never false success or automatic replay.
- Managed startup callbacks can acquire resources; stateful SDK calls outside an
  activation fail explicitly. Actual-PID ownership still rejects another process.
- Old-generation claims, subscriptions, handles and queued/in-flight operations
  cannot authorize effects after revocation or attach to a later activation.
- Owner exit and Apps/domain restart drain or visibly block old generation resources.
  Network withdrawal failure prevents address removal and conflicting activation.
- Repeated start/stop/restart/upgrade/rollback cycles leave no leaked owned paths,
  loaded specs/modules, private apps, workers or SDK resources. Platform state and
  other installed apps remain untouched.
- SD removal and controller failure during each material phase reconcile safely;
  enabled restoration uses a fresh generation. Unsupported metadata never migrates
  automatically or takes gateway management down.

## Validation and operational boundaries

- Run formatting, root `mix check`, `git diff --check` and focused static checks.
  Build affected target firmware and verify native ports; rebuild shared assets if
  their sources change. Report host, artifact and runtime results separately.
- Run focused app/SDK QEMU scenarios only on the user-owned session with suitable
  disposable devices and explicit permission for their lifecycle/storage actions.
  The existing apps scenario requires a fresh disposable disk; ask if unavailable.
- Do not start another bench, run `--ci`, reset existing guests, modify physical
  devices or run full `mix ci` without the required authorization.
- Implementation is complete only when the acceptance cases are qualified; if runtime
  validation is unavailable, state that qualification is pending rather than claim
  the hardening is proven. Commit/push and release actions remain separate requests.
