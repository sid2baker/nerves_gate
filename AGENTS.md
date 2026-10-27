# Nerves Gate

## KISS: deep modules, narrow interfaces

- Prefer direct Elixir/OTP and the simplest design solving today's problem.
- Judge modules by the knowledge they hide, not line count. Keep wrappers owning
  real policy, transport or hardware; remove wrappers that only rename calls.
- One concept, one name, one implementation. No mirrored command facades, generic
  operation dispatchers, single-implementation adapters or speculative frameworks.
- No legacy code: remove replaced APIs, deprecated shims, old route aliases,
  compatibility fallbacks and automatic migrations. Support the current contracts
  only. Reject unsupported firmware/configuration explicitly and never erase or
  rewrite live state merely to make it compatible.
- Keep seams for real board variation and the published typed SDK contract.
- Create safe errors where their meaning is known; no global reason catalogue.
- Document the current system, not the history of replaced code.

## Projects and ownership

- Application logic, tests and development tooling are Elixir. Prefer Req for HTTP;
  use external tools for actual firmware, networking, QEMU and Git operations.
- Root is `:nerves_gate_workbench`, not an umbrella. `firmware/`, `sdk/` and
  `systems/*` remain independent projects with distinct targets and releases.
- `apps/`: optional first-party ordinary Mix applications, independently packaged
  and tested. Never install, start or enable them automatically. Applications own
  equipment identities, addressing requirements, protocol sessions and use cases.
- `lib/workbench/`, `lib/workbench_web/`, `priv/workbench/`: host sessions, builds,
  apps, discovery, physical tools and workbench UI. Ordinary tasks start no session.
- `lib/simulator.ex`, `lib/simulator/`: locally supervised simulator and owned disposable
  QEMU processes, disks and private networks. Never attach controls to arbitrary VMs.
- `lib/scenarios.ex`, `lib/scenarios/`: one catalogue, runner and real scenarios.
  Check explicit requirements before preparation. Independent devices can run
  concurrently; `devices: :all` reserves every device and excludes manual controls.
- Scenario reservations and serialized `Workbench.Jobs` protect different resources.
  Jobs reserve lifecycle/shutdown admission with Runner until worker exit.
  Unknown RPC/control outcomes block further control/cleanup.
- `firmware/lib/nerves_gate/`: domains own commands, validation, admission,
  deadlines and persistence. Use named public domain functions, not infrastructure.
- `NervesGate.status/0` directly reads domains independently; `subscribe/0` belongs
  to the caller. `NervesGate` is a read/subscribe entry point and domain API index.
- Cellular and application network effects share Network's single worker/trial
  admission. A separate API module does not need a separate GenServer.
- Gateway LiveViews call local domains. Workbench device views explicitly subscribe
  to a remote **read-only** projection; there is no remote gateway-command proxy.
- Projections are sanitized read models, never authority. Subscribe before reading,
  resubscribe fresh after loss, and keep drafts separate. UI availability never
  replaces backend validation. Pure policies/read models perform no effects.
- SDK observations and administrative status/commands are distinct contracts.
  Preserve actual calling-PID ownership of subscriptions and network leases; no Tasks
  proxying those calls. Stateful SDK calls require managed activation membership.
  Membership resolution uses Plugins-owned generation bindings; assignment queries
  run in its responsive controller. Serial/CAN handles belong to plugin supervision,
  not SDK transport proxies. Assignment changes require checked whole-plugin stop.
  Trusted apps share the BEAM; the SDK is not a sandbox.
- `Plugins.Artifact` owns immutable archive/content verification; `Plugins.Loader` owns
  verified code loading and checked cleanup. Plugins owns serialized admission,
  protected generation bindings and schema-2 metadata. Never replace a registered
  version, backfill a digest, import old metadata or bypass blocked cleanup.
- Plugin pages are optional verified LiveComponents under `/plugins/:app`, not dynamically
  recompiled routers or separate servers. Gateway LiveViews are not SDK resource
  owners: call the app's supervised command process. Checked unload closes all app
  UI processes before removing code; never bypass busy-session cleanup.
- Firmware plugins are explicitly selected in `plugins/selection.exs`, built in
  isolated host processes and discovered from a verified read-only inventory.
  No device-side downloads/resolution or store workflow. Private dependency names
  belong to one plugin; shared library versions are deliberate firmware inputs.
  Preserve actual-PID resource ownership and never replay an uncertain operation.
- Keep genuine sharing through the firmware path dependency without starting its
  application on the host. Do not add a common library/UI kit without measured need.

## Safety

- Never flash physical devices, wipe storage, change workstation networking/VPN,
  or stop unrelated processes without explicit authorization.
- Breaking source changes do not authorize resetting a live bench or saved settings.
  Never delete locks/disks to force a cutover. Stale saved modem drivers fail closed;
  physical reprovisioning/reset is a separately authorized procedure.
- Keep login URLs, cookies, CSRF tokens, PINs/PAP credentials, private keys, SIM
  identifiers and VM identity disks out of projections, logs and uploaded artifacts.
- Physical SSH verifies known hosts; permissive owned-QEMU trust stays separate.
- Acceptance is not completion. A timeout does not cancel work. Never blindly retry
  writes, PIN attempts, firmware uploads or uncertain controls.

## Development and validation

- Run commands at the root. `mix setup` prepares tools/artifacts without building
  device firmware or booting devices. Apps are ordinary external Mix projects.
- The user owns `mix dev [APP_DIRECTORY]`. Do not launch/stop that session or
  boot/reset devices without authorization. Ask for an available session if needed.
- Focused checks use `mix test.qemu --only ID [--device ID]` against that session.
  Never use `--ci` to launch another bench without explicit authorization.
- Root tests own host tooling/shared UI integration; firmware `test/unit/` and
  `test/web/` own policy/codecs/gateway checks; SDK tests own its typed contract.
  Extend real scenarios instead of adding a hardware-mock suite or fake SDK backend.
- Repository host checks use native `Mix.Project.in_project/4` with state restoration.
  Target compilation and external app builds require isolated supervised OS
  processes, never target application compilation in the workbench VM.
- Run root `mix check` before commits: host tests, compile/format, firmware JS,
  credo, clone and architecture/smell checks, SDK tests and starter-app tests.
  It boots no devices and excludes dialyzer and target builds. Also run
  `git diff --check`. Never weaken `--check-locked`, deadlines or fault coverage.
- Full `mix ci` is expensive and belongs to the user unless separately requested.
  Report source, artifact, runtime and full-CI results distinctly.
- `mix format --force` formats root/subprojects, excluding system inputs.
- Firmware's host `mix assets.build` builds shared assets. Root
  `mix firmware [x86_64 | ec100] [--env dev | prod]`, workbench Build and local QEMU
  builds prepare assets before
  isolated target compilation. Include changed `firmware/priv/static/assets/` with
  sources. Gateway Elixir/HEEx changes require rebuilt guests.
- QEMU management uses explicit checkout-owned bridge/TAP preparation with `mix dev.network setup --subnet <private-/24>` and cleanup after the session stops. These change host networking and need explicit authorization; ordinary startup must not create/delete interfaces. Physical inspection needs no QEMU setup.
- Pi attaches to the unique hidden Workbench node with the `dev-environment` skill; inspect its verified directory from the runtime target, not a standalone device-connection loop.
- Documentation-only changes need no QEMU checks. Do not claim unperformed checks.
- Root/firmware share `VERSION` and `CHANGELOG.md`; SDK/systems keep independent
  versions. System inputs require a system version bump. Only SDK goes to Hex.
  Tags, publishing, retirement, commits, pushes and physical operations need a request.
- Protected CI owns publishing credentials; never put them in the workbench VM.
  Platform publication requires green routine CI and separate QEMU integration on
  the exact tagged main-branch commit. SDK development advances its own version;
  local starter apps may require that prerelease, never pretend a published SDK
  contains unreleased capabilities. Firmware records its commit in `source_revision`.
- `Workbench.Gateways` is the sole verified gateway directory. Inspection and
  application transfer use distribution; firmware upload uses strictly verified
  `Workbench.SSH`. Device maintenance logic is compiled, never shipped as source strings. Older firmware must be updated through an explicitly authorized
  external procedure; do not retain a compatibility fallback.
- Legacy equipment/joined network settings are rejected, not rewritten. Explicit
  migration or reset of existing devices still requires separate authorization.

## Start here

- [Architecture](docs/architecture.md)
- [Development](docs/development.md)
- [App development](docs/app-development.md)
- [Domain API index](firmware/lib/nerves_gate.ex)
