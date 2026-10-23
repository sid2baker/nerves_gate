# Architecture review

Source review of the project/build definitions, configuration, supervision,
device domains, UI projections, SDK/apps/storage, simulator ownership, physical
update paths and CI/release workflows. This is an assessment of the current
structure, not a refactoring specification or a hardware/security certification.
See [architecture](architecture.md) for the implementation map and the
[refactor plan](refactor-plan.md) for staged work and acceptance criteria.

## Overall assessment

**Keep the independent projects.** They have real differences in build target,
startup, consumers and release lifecycle:

- The root is a workstation product, including the simulator and workbench.
- Firmware is a Nerves application with host, EC100 and QEMU configurations.
- The SDK is an independently published, pure Elixir application contract.
- Systems produce independently versioned Linux/toolchain/boot artifacts, not
  application services.

An umbrella would not remove target/toolchain isolation or those release
boundaries. Another general-purpose shared project would introduce packaging,
configuration and dependency ownership before removing a demonstrated problem.
The simulator belongs with its host owner; a separate Mix project is not needed
just because it has a separate BEAM at runtime.

The main structural weakness is **implicit host coupling to firmware startup**,
not the nested directory layout. Root's `runtime: false` dependency hides neither
compilation cost nor the session's explicit use of `NervesGate.Application`.

## Important findings

| Finding | Evidence | Consequence |
| --- | --- | --- |
| Firmware is a genuine host code dependency | Root [`mix.exs`](../mix.exs), [`DeviceLive`](../lib/dev_web/device_live.ex), [`FactoryConnection`](../lib/dev/factory_connection.ex) | Components, projection subscriptions and Linux netlink helpers need owners; removing a path dependency is not just a test move. |
| Host services use the firmware supervisor | [`session.exs`](../priv/dev/session.exs), [`NervesGate.Application`](../firmware/lib/nerves_gate/application.ex) | PubSub, runner and workbench endpoint lifecycle depend on a device-named OTP application and its `rest_for_one` ordering. |
| Native project entry restores selected state, not the whole VM | Root [`mix.exs`](../mix.exs), [`Dev.configure/0`](../lib/dev.ex), [`configuration_test.exs`](../test/configuration_test.exs) | Tests must distinguish declared config, residual settings and actually running services. A leftover endpoint config is not evidence of a running endpoint. |
| UI and SDK are different read contracts | [`ProjectionServer`](../firmware/lib/nerves_gate/projection_server.ex), [`SDKBackend`](../firmware/lib/nerves_gate/sdk_backend.ex), [`Backend`](../sdk/lib/nerves_gate_sdk/backend.ex) | Do not turn the administrative projection into the public SDK or route bus claims through an intermediary process. |
| Admission and hardware ownership are separate | [`Dev.Operations`](../lib/dev/operations.ex), [`QemuTests`](../lib/simulator/qemu_tests.ex), [`Device`](../lib/simulator/device.ex) | Workbench serialization and per-device reservations are not interchangeable. Worker exit and uncertain-outcome handling are safety properties. |
| Physical and simulated devices have different trust paths | [`Dev.Devices`](../lib/dev/devices.ex), [`FirmwareUpdate`](../lib/dev/firmware_update.ex), [`FactoryProvisioning`](../lib/dev/factory_provisioning.ex) | Discovery does not grant authentication or simulator controls. Physical information is an explicit verified read, not a live QEMU subscription. |
| SDK restrictions are a supported interface, not a sandbox | [`Apps`](../firmware/lib/nerves_gate/apps.ex), [application model](applications.md) | Trusted app code and ordinary OTP callbacks can affect the shared runtime; installation validation does not create process/OS isolation. |

## Recommended sequence

These are proposed follow-up changes, not new orchestration policy.

### 1. Make host session supervision explicit

If making a structural change, start with the session tree, not project extraction.
Have the existing host session own its PubSub, runner and endpoint explicitly,
without starting the firmware application just to host those services. Keep the
firmware path dependency for the code genuinely reused today.

This would make `:nerves_gate_dev` ownership easier to reason about without adding
a Mix project or moving device policy. Preserve startup order, subscription
availability, endpoint config/reload behaviour, stop admission and MuonTrap/EPMD
cleanup. Do not implicitly start UI/runner services whenever a host task starts
the root application. Add a focused session regression before changing the tree.

**Completion criterion:** the workbench starts/stops its own services without
starting `:nerves_gate`, while gateway subscriptions and the existing QEMU
reservation owner are unchanged.

### 2. Test native orchestration's return-to-root contract

Keep `Mix.Project.in_project/4` for repository host checks. Add focused coverage
of the existing helper's successful and failing return paths: Mix project,
env/target, compiler options, code path, environment variables, firmware settings
and newly started subsystem supervision. Include repeated entry and a residual
endpoint setting, and verify that root listeners remain stopped.

Do not assert that every firmware-related application setting is globally absent;
`Dev.configure/0` merges configuration. Existing configuration/build tests cover
parts of this contract, but not the full helper's restoration on failure.

**Completion criterion:** a failed subsystem task cannot silently select a device
target or leave newly started firmware supervision running when root work resumes.
Loaded module state remains an explicit limitation, not a promised rollback.

OS-process isolation for these checks is a fallback only if a concrete,
reproducible cross-project failure cannot be addressed simply. It would change
current policy and add launch/output/error handling. Device builds and external
user apps already have the necessary process isolation; keep that boundary.

### 3. Align firmware-only host tests with their code owner

Root currently contains gateway-specific rendering and transport tests, for
example [`network_editor_test.exs`](../test/network_editor_test.exs),
[`storage_page_test.exs`](../test/storage_page_test.exs) and
[`gateway_socket_test.exs`](../test/gateway_socket_test.exs). Move firmware-only
cases into firmware's host test suite in a small follow-up, including their
minimal rendering/test dependencies and listener-free endpoint setup.

Keep workbench, shared-asset integration, CLI, session, admission and release
contracts at the root. Keep SDK/package tests in the SDK and real device I/O in
shared scenarios. Do not move every test mentioning `NervesGateWeb` merely to
make directories look independent.

**Completion criterion:** firmware checks exercise their own UI/security contract,
root checks still exercise actual cross-project integration, and root `mix ci`
continues to orchestrate both without duplicate suites or QEMU startup.

### 4. Defer shared-library extraction until there is a measured benefit

First measure host compile/dependency cost and inventory the actual reused
functions. A possible future extraction has to account for components/layouts,
subscription helpers, projection/status derivation and netlink access—not just
structs. `Status` also uses pure helpers from device-domain modules, so moving its
file alone does not sever dependencies.

Prefer a small, named responsibility with clear consumers over `shared/` or
`common/`. If the current path dependency remains cheaper to maintain, keep it.
Do not create a universal backend, plugin framework or umbrella to conceal it.

## Deployment constraint: management access

Before expanding deployment beyond trusted networks, settle the gateway's access
model. [`firmware.exs`](../firmware/config/firmware.exs) explicitly exposes an
unauthenticated management endpoint on all IPv4 interfaces. The strict CSP,
session-bound CSRF checks, USB-only SSH password recovery and cellular filtering solve
specific problems; they do not authenticate an ordinary LAN/VPN user.

Choose and test the intended exposure/authentication policy as a separate security
change. Until then, trusted-network access is a deployment requirement, not a
security feature inferred from Tailscale or the SDK. This takes precedence over
cosmetic project restructuring for broader production use.

## Preserve these boundaries

- Domain-owned admission, monotonic deadlines, rollback and unknown-outcome rules;
  no replacement with UI-derived actions or a global workflow coordinator.
- Serialized subscription/snapshot handoff and fresh resubscription after owner
  loss; no workstation cache masquerading as authoritative device state.
- Real disposable QEMU ownership, private management paths and resource release
  on worker death; no fake hardware backend or arbitrary-VM attachment.
- Typed SDK observations and caller-owned bus I/O, separate from administrative
  commands and fixture controls.
- Host asset preparation before isolated target builds; native-port verification
  and locked dependencies rather than wider timeouts to hide contamination.
- Separate read/review/confirm/write physical operations and immutable publishing;
  no publishing credentials in the workbench, or device secrets in projections
  and uploaded artifacts.

## Confidence and limits

The project graph, configuration paths, key process trees and command/observation
ownership above were traced in source, including tests and workflow definitions.
This provides a firmer basis than inferring architecture from directory names.

It does not prove every restart interleaving, storage failure, upstream dependency
behaviour or third-party SDK consumer. This documentation review did not start
QEMU, build firmware, run full CI, publish artifacts or operate physical hardware.
Follow-up behaviour changes need their own focused checks; physical bus and
power-loss qualification still require an explicitly authorized bench.
