# Host/firmware boundary refactor plan

Status: proposed; no implementation steps completed. Creating this plan does not
authorize device startup, physical operations, publishing or committing changes.

Based on the [architecture map](architecture.md) and
[review](architecture-review.md). The goal is clearer ownership with fewer hidden
startup dependencies, not a new project structure.

## Scope and invariants

- Keep the root, firmware, SDK and systems as independent Mix projects.
- Keep the root's firmware dependency for shared components, projections,
  subscriptions and netlink helpers. `runtime: false` remains intentional.
- Keep repository host checks native through `Mix.Project.in_project/4`.
  Device compilation and external user-app builds remain isolated supervised
  OS processes.
- Preserve domain APIs, SDK contracts, device supervision and firmware behaviour.
- Preserve QEMU reservations, worker lifetime, uncertain-outcome blocking and
  private hardware ownership. Do not merge `Dev.Operations` with `QemuTests`.
- Ordinary host application startup must not start an endpoint, runner, simulator
  session, device networking or VPN service.
- Do not change system artifact inputs, release versions or generated assets
  unless an independently necessary change requires it.

## Delivery order

Use three small, independently reviewable changes:

1. Characterize native project restoration and current session expectations.
2. Give the explicit workbench session its own host service supervision.
3. Move firmware-only UI/security host tests to their owning project.

Land regression coverage before changing lifecycle wiring. Keep test relocation
separate from supervision changes so failures have a narrow cause. Update current
architecture documentation alongside each implementation change.

## Phase 1 — Lock down boundary behaviour

### Files

- Root `mix.exs`: existing native `run/3` helper.
- `lib/dev.ex`: configuration merge behaviour.
- `test/build_config_test.exs`, `test/configuration_test.exs`,
  `test/session_test.exs` and a focused orchestration test if needed.

### Work

- [ ] Test successful, failing and repeated native subsystem entry.
- [ ] Snapshot and check restoration of the Mix project, environment, target,
  compiler options, code path, environment variables and firmware application
  configuration on both success and failure.
- [ ] Verify a newly started subsystem application is stopped on return; preserve
  the distinction between newly started and previously running applications.
- [ ] Cover inherited target variables, a temporary variable introduced by the
  subsystem, and residual gateway endpoint settings.
- [ ] Verify root configuration still selects host services and does not start a
  gateway/workbench listener merely because an endpoint setting exists.
- [ ] Record the session startup/stop contract needed by Phase 2, including
  PubSub availability and the existing dependency-ordered restart behaviour.

Exercise the real restoration helper with a bounded test task, not a copied
implementation. Prefer the smallest testability change if private access prevents
coverage; do not build a generic project runner or hardware-mock framework.
Tests mutating VM-wide Mix/application state must be serialized and restore their
own state even when assertions fail.

### Acceptance

- [ ] Failure cannot leave root work using the subsystem project or target, or
  newly started firmware supervision.
- [ ] Configured-but-stopped endpoints remain a supported state.
- [ ] Tests do not claim restoration unloads BEAM modules or reverses all
  dependency/application side effects; whole-VM rollback is not the contract.
- [ ] No device build, QEMU process or workstation VPN starts during these checks.

## Phase 2 — Own workbench services on the host

### Current and intended ownership

Current explicit session:

```text
Dev.Supervisor → tasks, app projects, discovery, operations
NervesGate.Supervisor → PubSub, QemuTests, DevWeb.Endpoint
```

Intended explicit session:

```text
Dev.Supervisor → tasks, app projects, discovery, operations
host-owned session services → PubSub, QemuTests, DevWeb.Endpoint
owned simulator BEAM → Simulator → device owners
```

The second tree belongs to the explicit session, not automatic root application
startup. Keep the existing firmware application unchanged on devices.

### Files

- `priv/dev/session.exs`: service startup and cleanup.
- `lib/dev/application.ex`: preserve ordinary host startup semantics.
- `lib/dev/launcher.ex`, `priv/dev/host.exs`: existing ownership chain; change only
  if required by the new service owner.
- `config/config.exs`, `lib/dev_web/endpoint.ex`: existing endpoint configuration.
- `test/session_test.exs`, `test/configuration_test.exs`,
  `test/admission_test.exs`, `test/operations_test.exs`.

### Work

- [ ] Attach an ordinary host-owned service supervisor to the existing explicit
  session owner. Preserve `PubSub → QemuTests → Endpoint` startup ordering and
  the current `rest_for_one` restart relationship and restart limits.
- [ ] Use a small host module only if it makes that lifecycle clearer/testable;
  do not add a configurable service registry or another Mix project.
- [ ] Remove the session override of `:nerves_gate, :services` and its explicit
  `Application.ensure_all_started(:nerves_gate)` / stop calls.
- [ ] Keep the firmware dependency `runtime: false`; retain root's default empty
  device-service configuration.
- [ ] Initially retain `NervesGate.PubSub` as the shared bus name. A rename is not
  necessary to establish ownership and would broaden this change.
- [ ] Keep `DevWeb.Endpoint` configuration under `:nerves_gate_dev`, its private
  Unix listener, loopback listener and code reload behaviour.
- [ ] Account explicitly for firmware application startup side effects:
  distribution-cookie initialization, credential log filtering and endpoint
  `config_change/2` forwarding. Preserve required host behaviour in the host owner;
  do not retain firmware startup merely to obtain incidental side effects.
- [ ] Stop/unsubscribe session services in dependency-safe order before tearing
  down the owned simulator/EPMD. Preserve cleanup on startup failure and exceptions.
- [ ] Leave `flock`, MuonTrap, session identity/stop admission, hidden simulator
  distribution and QEMU handle ownership intact.

### Acceptance

- [ ] An explicit workbench session runs PubSub, the runner and endpoint without
  `:nerves_gate` appearing in started applications or a `NervesGate.Supervisor`.
- [ ] Ordinary root commands start neither session services nor device domains.
- [ ] Startup failure cleans up only owned children and releases the session lock
  after cleanup, never by deleting the lock file.
- [ ] CLI state/stop operations, endpoint reload and projection subscriptions still
  work. Disconnected devices remain unavailable, not stale authoritative state.
- [ ] Runner/endpoint failures preserve the intended restart and reservation
  semantics; no transparent reset of uncertain QEMU hardware is introduced.
- [ ] No gateway HTTP endpoint, VintageNet or tailscaled starts on the workstation.

## Phase 3 — Put firmware tests with firmware

### Candidate moves

Review each test's assertions before moving the whole file:

| Root file | Intended owner |
| --- | --- |
| `test/network_editor_test.exs` | Firmware host UI tests |
| `test/cellular_panel_test.exs` | Firmware host UI/credential-admission tests |
| `test/storage_page_test.exs` | Firmware host UI tests |
| `test/gateway_socket_test.exs` | Firmware host transport/security tests |
| `test/theme_test.exs` | Firmware-owned component/CSP assertions; retain genuine workbench integration at root |

Use `firmware/test/web/` for web tests and keep `firmware/test/unit/` for pure
policy/codecs. Do not move tests solely because they mention a shared component.

### Work

- [ ] Move selected cases once, preserving their assertions and coverage.
- [ ] Add only missing host-test dependencies, such as Floki, to firmware; do not
  add runtime device dependencies or enable a host gateway listener.
- [ ] Preserve the real listener-free endpoint setup and environment restoration
  in socket/security tests. Share setup only where actual duplication warrants it.
- [ ] Correct root-relative fixture/source paths and test module names as needed.
- [ ] Retain root workbench rendering, shared-asset integration, launcher, CLI,
  admission, configuration, build and release contracts.
- [ ] Keep SDK/package contract tests in the SDK and real device I/O in the shared
  scenario catalogue; do not replace those scenarios with host hardware mocks.
- [ ] Confirm native firmware host checks include the new test directory and root
  orchestration runs each suite once.
- [ ] Update project dependency locks deliberately if adding test dependencies,
  retaining shared root/firmware lock consistency and `--check-locked`.

### Acceptance

- [ ] Firmware host tests cover gateway rendering, credential admission, CSP and
  session-bound WebSocket CSRF without devices or HTTP listeners.
- [ ] Root tests still cover actual host integration, with no duplicated suites.
- [ ] Device dependencies, compiled assets, SDK behaviour and target configuration
  are unchanged by test relocation.

## Validation and authorization

For each implementation change:

1. Run formatting and the focused host tests for changed behaviour. Phase 1/2
   coverage must include failure cleanup, not only the happy path.
2. Run firmware host checks through native project entry when relocating tests;
   do not introduce shell-out Mix orchestration as a shortcut.
3. Inspect the diff for unintended lock, system, asset or runtime changes.
4. Update `architecture.md` to describe what now runs, not the proposed tree.

For Phase 2, a session smoke check also matters: empty session startup, CLI state,
reload and graceful stop without device boot. Perform it only with explicit
permission for an owned temporary session; never take over the user's `mix dev`.
After host checks, request the user's running disposable bench for a focused
`mix test.qemu --only projection_stream --device <id>` check. This scenario
reserves the whole bench despite selecting an initiating device; confirm it is
available and authorized first. Add another scenario only if its behaviour was
affected. Never use `--ci` to obtain a bench implicitly.

The user runs final root `mix ci`; do not run a full QEMU suite for this refactor.
No firmware build, physical flash, networking change, tag, publish, commit or push
is implied by the plan. Report any unperformed lifecycle/device checks explicitly.

## Deferred decisions

- **Shared-library extraction:** first measure clean/incremental host compile cost
  and inventory actual shared calls. Extract only a narrow named responsibility
  with a demonstrable benefit; otherwise keep the path dependency.
- **OS-isolated repository host checks:** reconsider only after a reproducible
  failure that the simple native restoration contract cannot reasonably address.
- **Gateway authentication/exposure:** separate security work before expanding
  deployment beyond trusted networks. Do not mix an access-policy redesign into
  lifecycle/test relocation or imply that CSRF/CSP authenticates LAN users.
- **SDK, domain and BSP redesign:** outside this plan. Preserve their existing
  ownership and independently versioned artifacts.

## Completion checklist

- [ ] Three focused changes reviewed with current documentation.
- [ ] Workbench session no longer starts the firmware OTP application.
- [ ] Native project restoration is covered on success and failure.
- [ ] Firmware-only host tests live with firmware, without lost assertions.
- [ ] Focused checks and outstanding validation are recorded.
- [ ] No new project, generic sharing layer, public API or automatic hardware action.
