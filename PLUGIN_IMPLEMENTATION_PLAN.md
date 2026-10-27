# Pure-BEAM plugin implementation plan

## Status and scope

The subsequent [hardware assignment/RTU cutover](HARDWARE_PLUGIN_ASSIGNMENT_PLAN.md)
replaces SDK bus proxies with exclusive assignments and extends Modbus to TCP/RTU
in plugin 0.2.0. It uses the existing firmware UART driver, not a native plugin
payload. The validation summary below records the initial bundled-plugin cutover.

Source implementation now provides firmware-selected `tailnet_subrouter` and
`modbus_plugin` (yamodbus 0.1.0), build-generated read-only inventory, source-aware
artifacts, one renamed Plugins manager, explicit version selection and `/plugins`
controls. Store catalogue/download/release code and old gateway routes are removed.
The fixed SDK bridge and improved interface picker are retained.

Validation: `mix check` passed (14 SDK, 139 firmware, 168 root, 9 subnet-router,
6 Modbus tests, plus 3 generated-project tests). The Modbus suite also passed
20 repeated runs after correcting supervised client shutdown and test isolation. x86_64 dev and EC100 dev firmware
builds passed. Artifact inspection verified both entry points and yamodbus's private
closure without loading plugin code into the host. Host Modbus tests exercise actual
TCP reads/timeouts/cleanup against a disposable peer. Upstream yamodbus 0.1.0 emits
Elixir 1.20 bitstring pinning warnings; its source has not been patched locally.

The focused `plugins` QEMU scenario and existing fault scenarios have not been run.
No device boot/reset, physical deployment, metadata migration, commit, push or
publication was performed. Runtime qualification remains pending; builds and host
tests are not evidence that the device fault scenarios passed.

The goal is a gateway extended by trusted protocol plugins, not an app store.
For this iteration, support ordinary Elixir/Erlang libraries and OTP applications.
Use Modbus TCP with the requested yamodbus library as the first protocol example.
S7 can follow under the same contract. EtherCAT, native stacks, NIFs contributed
by plugins, executable ports and new kernel/driver support are out of scope.
Plugins may use native facilities already provided by compatible firmware; they
must not bring their own native runtime payloads.

## Target architecture

```text
Firmware
  ├─ device drivers, Internet/management, shared runtime libraries
  ├─ one plugin lifecycle/resource owner
  ├─ fixed SDK integration bridge and optional gateway-hosted UI
  └─ selected, firmware-bundled plugins
       └─ ordinary supervised OTP applications
            ├─ pure-BEAM protocol dependencies
            ├─ equipment connections, polling and protocol semantics
            └─ plugin-owned configuration, status and optional UI
```

A plugin is an ordinary OTP application plus its compatible dependency closure.
It is not a new process model, container, protocol adapter framework or sandbox.
Plugin workers call ordinary libraries directly. For example, Modbus TCP and S7
connections use normal TCP through their selected libraries, not SDK socket APIs.

The firmware owns shared infrastructure, lifecycle admission and exclusive
hardware-resource allocation. Plugins own equipment identity, protocol addressing,
discovery, connection supervision, polling, commands and interpretation of data.
Do not move those concerns into `NervesGate.Equipment` or add per-protocol SDK calls.

## Decisions

1. **Firmware-selected plugins first.** Build selected plugins and their dependency
   closures into the firmware image as immutable managed artifacts. They still use
   the plugin manager for activation; do not also auto-start them as firmware OTP
   dependencies. Adding or changing a bundled plugin initially requires a firmware
   rebuild. Runtime installation is not the primary product workflow.
2. **One manager.** Evolve the existing Apps artifact/loader/owner machinery rather
   than add a second plugin supervisor or activation engine. Preserve immutable
   identities, checked cold activation, health checks, rollback limits, UI drainage
   and actual-PID/generation ownership.
3. **Ordinary OTP integration.** Use the OTP application specification and supervision
   tree. Retain optional health-check and UI declarations; do not invent a second
   `Plugin.start/stop` callback protocol. Starting and stopping belong to OTP and
   the manager. No mandatory configuration schema, event bus or adapter registry.
4. **Small SDK.** Retain platform observations, data-directory access, lifecycle-fenced
   subscriptions and resource reservations where needed. Keep the fixed firmware
   bridge, not configurable backend implementations. Do not wrap ordinary TCP,
   protocol libraries or every Elixir operation.
5. **Direct LiveView dependencies.** UI plugins declare compatible LiveView libraries
   directly. The SDK remains independent of web libraries. Retain the generic host
   page and supervised-plugin command boundary; no wrapper macro without a real job.
6. **Trusted code.** Plugins have the privileges of ordinary firmware code and can
   exhaust resources or bypass conventions. Resource APIs prevent cooperative
   conflicts; they do not enforce a security sandbox around arbitrary BEAM code.
7. **Explicit operation.** New plugins are stopped/disabled unless the firmware
   product selection explicitly defines enabled intent. The first implementation
   defaults to stopped. Discovery, viewing UI and building firmware never connect
   to equipment or change network configuration.

## Dependency policy: one BEAM, one namespace

The VM cannot load independent copies of the same application/module for different
plugins. A plugin architecture does not remove that constraint.

- Resolve dependencies on the build host using committed lockfiles, never on the
  device. Package the complete non-platform runtime closure, not just the main app.
- Treat firmware libraries, including SDK/Phoenix and their relevant transitive
  dependencies, as platform-supplied. Preserve explicit compatibility checks and
  never package or stop a second copy.
- Initially retain exclusive ownership of private dependency application/module
  names. Two plugins cannot privately bundle even identical copies of a library.
  Fail the firmware build before delivery with both owners and the conflict named.
- If two selected plugins need the same dependency, deliberately promote one
  compatible version into the firmware's shared-library set and rebuild both
  against it. Do not silently deduplicate, rewrite namespaces, choose a version
  on-device or stop a shared dependency when one plugin stops.
- Allow one protocol plugin to supervise multiple configured equipment connections;
  do not require one plugin package per piece of equipment.
- A pure-BEAM build must have no plugin-contributed native runtime artifacts. Inspect
  dependency metadata and packaged contents; reject native libraries/executable
  payloads while allowing ordinary `priv` data. Document that static inspection
  cannot prove arbitrary trusted code never dynamically loads external code.

## Implementation phases

### 1. Fix the contract and remove store-centric product assumptions

- Keep `NervesGate.Plugins`, SDK, package task, workbench commands and
  `/plugins` UI aligned with their plugin responsibilities. Record the retained lifecycle
  invariants before changing names.
- Establish plugin terminology in public documentation and product UI. Keep OTP
  application names distinct from plugin identity where needed; no mass replacement
  of the Elixir/OTP concept of an application.
- Remove first-party GitHub catalogue/download/review controls, their product-only
  release workflow and obsolete catalogue tests/docs. Preserve firmware and SDK
  release tooling and reusable archive integrity checks.
- Keep local build/package/install tooling for development and qualification, not
  as an advertised app-store replacement. Do not add arbitrary URL installers.
- Update public API/route/module names coherently where they genuinely describe
  the product manager. Do not retain old route aliases or deprecated shims.
- Reassess the current uncommitted interface-picker and fixed-bridge changes and
  retain their useful behavior; do not discard them as part of renaming.

**Gate:** documented responsibilities match source ownership; exactly one lifecycle
manager remains, and no product workflow requires a GitHub app release.

### 2. Build complete, validated pure-BEAM plugin artifacts

- Extend `sdk/lib/mix/tasks/nerves_gate.package.ex` and the existing package/artifact
  validation rather than introduce a second archive format.
- Build independent plugin projects in isolated Mix processes. Package `.app`, BEAM
  files and ordinary `priv` data for the main application and private dependencies.
- Validate missing/transitive dependencies, SDK/platform compatibility, duplicate
  applications/modules, reserved names, paths, sizes and immutable digests.
- Add the pure-BEAM restrictions above to the plugin build/admission path. Existing
  support for other artifact types must not accidentally bypass the new policy.
- Validate the complete selected set during firmware assembly, including conflicts
  between plugins that would otherwise only fail at activation.
- Do not evaluate plugin code in the workstation/workbench VM during inspection.

**Gate:** a real external pure-BEAM dependency is packaged and validated; incompatible,
conflicting, incomplete or native-payload artifacts fail with actionable diagnostics.

### 3. Bundle plugins in firmware through the existing lifecycle manager

- Add one explicit build-time list of plugin project/artifact inputs to firmware
  assembly. Do not create discovery registries or a general deployment framework.
- Put verified, pre-extracted immutable artifacts in a read-only firmware-owned
  location. Retain their original archives/digests for verification. Do not copy
  them into the writable SD artifact store on every boot.
- Extend the existing artifact handling only as needed to distinguish firmware-owned
  read-only artifacts from developer-installed writable artifacts. Use the same
  validation, owner records, activation worker, namespace checks and UI cleanup.
- Reconcile firmware-provided versions deterministically on boot. Persist enabled
  intent separately from read-only code. Never silently activate an unrelated
  version because an old selected version disappeared from a firmware image;
  report unavailable selection and require an explicit decision.
- Starting a bundled plugin must not require an SD card merely to read its code.
  Remove blanket SD admission only for firmware-owned artifacts. Plugins using
  `Storage.data_dir/1` still require ready application storage; do not invent a
  silent `/data` fallback or promise their persistence without it.
- Preserve SD identity/removal protection for developer-installed artifacts and
  SD-backed resources. Do not infer that a bundled plugin using an SD data handle
  is unaffected by removal; retain explicit storage-unavailable handling.
- Firmware-owned artifacts cannot be overwritten or deleted through plugin
  management. Stop/disable is allowed; changing/removing bundled code requires a
  firmware build. Rollback is only possible to a verified artifact still available.

**Gate:** bundled code activates through the manager without SD, starts disabled,
obeys stop/health/UI/ownership rules and never writes into the firmware artifact root.

### 4. Implement one real protocol plugin: Modbus TCP

- Evaluate a maintained pure-BEAM library for licensing, OTP/Elixir compatibility,
  transitive dependencies, maintained client APIs and connection supervision.
  Do not pick a library solely from its name or add both S7 and Modbus at once.
- Create one independent example plugin with that library as an ordinary dependency.
  Its own supervisor owns client processes and per-device connections.
- Implement explicit configure/connect/disconnect, bounded read polling, status and
  structured errors. Keep configuration drafts separate from applied state.
- Begin with read-only operations. Exclude register writes and automatic equipment
  discovery until separately designed and tested. TCP reconnects must not become
  automatic replay of uncertain commands.
- Optional gateway-hosted LiveComponent calls the plugin's supervised API, never
  acquires resource ownership in the host LiveView. Display actual readiness and
  explain unavailable prerequisites, as in the subnet-router interface-picker fix.
- Do not make Internet-port TCP access require an exclusive local-interface claim:
  connecting to an equipment address is different from reconfiguring a port.
- Keep the subnet-router starter as a separate optional plugin illustrating
  exclusive local-network ownership, not as the protocol-plugin abstraction.

**Gate:** the real library communicates over actual TCP with a disposable protocol
peer, reports timeouts/disconnects and stops all owned workers/connections cleanly.
This is protocol integration evidence, not qualification against vendor equipment.

### 5. Qualify, cut over documentation and remove obsolete machinery

- Extend existing `lib/scenarios/` managed lifecycle/SDK/UI fixtures, not a parallel
  hardware-mock suite. Add a supervised disposable Elixir protocol peer on the
  owned private QEMU network for deterministic Modbus requests/responses.
- Exercise bundled/private dependency startup, dependency failure, multiple plugin
  coexistence, conflicting libraries, repeated start/stop, manager restart, missing
  selected versions, health failure, busy cleanup and UI teardown.
- Verify actual caller ownership through the fixed SDK bridge. Confirm plugin stop
  cannot stop shared platform libraries or another plugin's workers/resources.
- Test no-SD bundled startup separately from SD-backed data and developer installs.
  Test removal/errors without claiming persistence or cleanup succeeded prematurely.
- Document firmware selection/build, ordinary library use, dependency ownership,
  configuration responsibility, trusted-code limits and cold lifecycle behavior.
- Remove stale store-specific templates, scenarios, commands and docs. Keep one
  supported way to build, activate and inspect plugins.
- Decide the metadata cutover explicitly before implementing schema/name changes.
  Do not automatically adopt, migrate, format or erase existing installations.
  If old metadata is incompatible, leave it intact and report the required action.

**Gate:** source checks/builds and authorized runtime scenarios pass, with results
reported separately. Unexecuted QEMU or hardware cases remain explicitly pending.

## Validation and rollout

- Run focused package, firmware policy, SDK and component tests during each phase.
- Run `mix check` and relevant x86_64/EC100 builds after integrated changes; build
  changed assets and include generated assets when their sources change.
- Run focused scenarios only on user-started, disposable supervised devices, with
  explicit authorization for device lifecycle changes. Never launch another bench
  with `--ci` or run full `mix ci` on the user's behalf.
- Do not deploy this cutover to the physical gateway as part of implementation.
  It currently has a separately installed subnet-router version; preserve that
  installation and settings until a separately reviewed update/cutover is approved.

## Completion criteria

- A selected pure-BEAM protocol plugin and its library run like normal preinstalled
  OTP code, without a protocol-specific SDK, separate web server or store service.
- Firmware builds reject incompatible plugin sets before delivery.
- One manager retains truthful lifecycle, resource ownership and failure semantics.
- UI remains optional; headless plugins do not inherit LiveView dependencies.
- The device performs no package resolution, dependency downloads or unattended
  plugin updates. Native expansion and runtime distribution are later decisions.
