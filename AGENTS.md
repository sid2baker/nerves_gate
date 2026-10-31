# Nerves Gate

## Keep it stupidly simple

Every change is judged first by whether it is the simplest design that solves
today's problem.

- **Deep modules, narrow interfaces.** A module earns its place by the knowledge
  it hides. Callers pass intent and get results; they do not repeat the callee's
  constants, lists, layouts or checks. Remove wrappers that only rename calls.
- **One source of truth.** Each fact (a target list, a storage layout, a board's
  boot files, a validation rule) lives in exactly one place. Others ask its owner
  or are checked against it by a test; never copy it "for convenience".
- **One concept, one name, one implementation.** No mirrored facades, generic
  dispatchers, single-implementation adapters or speculative frameworks. Name
  modules after what they do, not after the first board that used them.
- **Data for wiring, modules for behaviour.** Put board constants in board config
  and share the implementation. Keep a board-specific module when it hides real
  hardware or storage behaviour; do not force unlike boards through one abstraction.
- **No legacy.** Remove replaced APIs, shims, aliases, fallbacks and automatic
  migrations. Reject unsupported firmware/configuration explicitly with a clear
  message; never erase or rewrite live state to make it compatible.
- Errors are created where their meaning is known; no global reason catalogue.
- Document the current system, not the history of replaced code.
- While implementing, note nearby complexity you could hide or delete and report it.

## Tools for changes

- Load the applicable Elixir skill before implementation (`elixir-web` for UI).
  Elixir code: `elixir_ast_search`/`elixir_ast_replace` for structural search and
  refactors, `edit` for small exact changes, `elixir_eval` for project APIs and
  runtime checks, LSP for references/diagnostics. Never use Python/shell rewrite
  scripts or blind string replacement for source changes.
- Shell is for Git, external CLIs (fwup, rkdeveloptool, Docker) and final Mix gates.
- One writer per file: do not parallelize dependent reads, moves and edits.

## Projects and ownership

- Application logic, tests and tooling are Elixir; prefer Req for HTTP. External
  tools only for firmware, networking, QEMU and Git.
- Root `:nerves_gate_workbench` is not an umbrella. `firmware/`, `sdk/`,
  `systems/*` and `plugins/*` are independent projects with their own targets,
  tests and releases.
- `firmware/lib/nerves_gate/`: domains own commands, validation, admission,
  deadlines and persistence; call named public domain functions. `NervesGate` is
  the read/subscribe entry point and domain API index. Cellular and application
  network effects share Network's single worker/trial admission.
- Boards: `config/<target>.exs` declares hardware as data (`:board`). EC100 and
  EM300 are physical RK3506 targets, x86_64 is QEMU. `Workbench.Builds` owns which
  targets can be built and which are physical; each `systems/nerves_system_<board>`
  owns its layout and its factory flash engine.
- Projections are sanitized read models, never authority. Subscribe before
  reading, resubscribe after loss, keep drafts separate. UI availability never
  replaces backend validation. Workbench device views subscribe to a remote
  read-only projection; there is no remote gateway-command proxy.
- SDK observations and administrative commands are distinct contracts. Preserve
  the calling PID's ownership of subscriptions, leases and serial/CAN handles; no
  proxy Tasks. Stateful SDK calls need managed activation membership. Assignment
  changes require a checked whole-plugin stop. Membership uses Plugins-owned
  generation bindings; assignment queries stay in its responsive controller.
  Trusted plugins share the BEAM; the SDK is not a sandbox.
- Plugins are explicitly selected in `plugins/selection.exs`, built in isolated
  host processes and discovered from a verified read-only inventory. Never start,
  enable or assign them automatically. `Plugins.Artifact` verifies content,
  `Plugins.Loader` loads and cleans up; Plugins owns serialized admission and
  schema-2 metadata. Never replace a registered version, backfill a digest,
  import old metadata or bypass blocked cleanup. No device-side downloads or
  dependency resolution; private dependency names belong to one plugin.
  Plugin pages are verified LiveComponents under `/plugins/:app`; checked unload
  closes their UI processes first. LiveViews call supervised plugin commands,
  never own SDK resources themselves.
- Workbench (`lib/workbench*`, `priv/workbench/`): sessions, builds, gateway
  directory, physical tools and UI. `Workbench.Gateways` is the sole verified
  directory; firmware upload uses strictly verified `Workbench.SSH`. Serialized
  `Workbench.Jobs` and scenario reservations protect different resources; unknown
  outcomes block further control/cleanup. Jobs reserve lifecycle/shutdown
  admission until worker exit. Raw `:erpc` stays in owning transports; maintenance
  logic is compiled, never shipped as source strings. Unsupported firmware needs
  an explicitly authorized external update, not a compatibility fallback.
- Simulator (`lib/simulator*`) owns disposable QEMU processes, disks and private
  networks only. Scenarios (`lib/scenarios*`) are one catalogue and runner.
  Check explicit requirements before preparation; `devices: :all` excludes
  manual controls and reserves every device.
- Share genuine code through the firmware path dependency without starting its
  application on the host. No common library/UI kit without measured need.

## Safety

- Never flash devices, wipe storage, change workstation networking/VPN or stop
  unrelated processes without explicit authorization. Source changes never
  authorize resetting a live bench or saved settings, or deleting locks/disks.
- Keep login URLs, cookies, CSRF tokens, PINs/PAP credentials, private keys, SIM
  identifiers, serials/MACs and VM identity disks out of projections, logs,
  artifacts and the repository.
- Physical SSH pins host keys reported over authenticated distribution. Permissive
  trust for owned QEMU stays separate. Unsupported saved network/modem settings
  fail closed; changing or resetting them needs separate authorization.
- Acceptance is not completion; a timeout does not cancel work. Never blindly
  retry writes, PIN attempts, firmware uploads or uncertain controls.

## Development and validation

- Run commands at the root. `mix setup` prepares tools without building firmware
  or booting devices. The user owns `mix dev`; do not start/stop it or boot/reset
  devices without authorization. See `docs/development.md` and `mix help`.
- Observe with `mix dev.doctor`, `mix gateway.list/inspect/logs`, `mix dev.job`.
  Focused checks: `mix scenario.run ID --device TARGET` against that session.
  `mix simulator.reset` erases disks and needs confirmation. QEMU network setup
  (`mix dev.network setup`) changes host networking and needs authorization.
- Pi attaches with `dev-environment` to this checkout's latest Workbench; reread
  `_build/workbench/session.json` and verify root and session ID before device
  operations. Reattach after session/node changes; do not choose another checkout's
  node or improvise connection loops. Report retargeting limitations instead of
  bypassing them or treating a Pi restart as an Erlang requirement.
- Tests: root for host tooling/UI, firmware `test/unit` and `test/web`, SDK for
  its contract, systems for their layouts. Extend real scenarios instead of
  hardware mocks or a fake SDK backend. Host checks use `Mix.Project.in_project/4`
  with state restoration. Target and external plugin builds run in isolated
  supervised OS processes, never in the workbench VM.
- Before commits: root `mix check` and `git diff --check`. Never weaken
  `--check-locked`, deadlines or fault coverage. `mix ci` is the user's unless
  requested. Report source, artifact, runtime and CI results separately, and
  never claim unperformed checks.
- `mix firmware [x86_64 | ec100 | em300] [--env dev | prod]` builds assets, then
  the target in isolation. Commit changed `firmware/priv/static/assets/`. Gateway
  code changes need rebuilt guests.
- Root/firmware share `VERSION` and `CHANGELOG.md`; SDK and systems version
  independently, and system input changes bump the system version. Only the SDK
  goes to Hex. Tags, publishing, commits, pushes and physical operations need a
  request; publishing credentials stay in protected CI. Platform publication
  requires green routine CI and separate QEMU integration on the exact tagged
  main-branch commit. SDK prereleases must honestly declare unreleased contracts;
  firmware records its commit in `source_revision`.

## Start here

- [Architecture](docs/architecture.md)
- [Development](docs/development.md)
- [Plugin development](docs/plugin-development.md)
- [Domain API index](firmware/lib/nerves_gate.ex)
