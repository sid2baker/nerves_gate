# Architecture review

Assessment of the current project/build boundaries, configuration, supervision,
device domains, UI projections, SDK/apps/storage, simulator ownership and physical
update paths. See [architecture](architecture.md) for the implementation map and
the [completed host-session change](refactor-plan.md) for scope and validation.

## Overall assessment

**Keep the independent projects.** They differ in build target, startup,
consumers and release lifecycle:

- Root owns the workstation workbench and simulator.
- Firmware is a Nerves application with host, EC100 and QEMU configurations.
- SDK is an independently published pure Elixir application contract.
- Systems produce independently versioned Linux/toolchain/boot artifacts.

An umbrella would not remove target/toolchain isolation or release boundaries.
Another shared project adds packaging and dependency ownership before addressing
a demonstrated problem. The simulator belongs with its host owner despite using
a separate BEAM at runtime.

## Current ownership

The explicit workbench session owns PubSub, the QEMU runner and its endpoint via
[`Dev.SessionServices`](../lib/dev/session_services.ex). Ordinary host tasks start
none of these services. The firmware application remains stopped on the host.

Root still deliberately depends on firmware code: components/layouts, projection
subscriptions, status derivation and Linux netlink helpers. `runtime: false`
prevents application startup, not compilation or shared code use. Firmware's
host suite owns its gateway editor, SIM panel, storage page and socket-security
tests; root retains workbench and real cross-project integration tests.

## Important boundaries

| Boundary | Evidence | Consequence |
| --- | --- | --- |
| Host code reuse is not firmware startup | Root [`mix.exs`](../mix.exs), [`SessionServices`](../lib/dev/session_services.ex), [`DeviceLive`](../lib/dev_web/device_live.ex), [`FactoryConnection`](../lib/dev/factory_connection.ex) | Keep the path dependency while it serves real consumers. Do not start device services to obtain shared helpers. |
| Native project entry restores selected state, not the whole VM | Root [`mix.exs`](../mix.exs), [`Dev.configure/0`](../lib/dev.ex), [`configuration_test.exs`](../test/configuration_test.exs) | Distinguish declared config, residual settings and running services. Leftover endpoint config does not imply a listener. |
| UI and SDK are separate contracts | [`ProjectionServer`](../firmware/lib/nerves_gate/projection_server.ex), [`SDKBackend`](../firmware/lib/nerves_gate/sdk_backend.ex), [`Backend`](../sdk/lib/nerves_gate_sdk/backend.ex) | Do not expose the administrative projection through the SDK or lose caller identity for bus claims. |
| Admission and hardware ownership are separate | [`Dev.Operations`](../lib/dev/operations.ex), [`QemuTests`](../lib/simulator/qemu_tests.ex), [`Device`](../lib/simulator/device.ex) | Workbench serialization and per-device reservations protect different resources. Release on worker exit and uncertain-outcome blocking must remain. |
| Physical devices and QEMU have different trust paths | [`Dev.Devices`](../lib/dev/devices.ex), [`FirmwareUpdate`](../lib/dev/firmware_update.ex), [`FactoryProvisioning`](../lib/dev/factory_provisioning.ex) | Discovery grants neither authentication nor simulator controls. Physical information is explicitly read over verified SSH. |
| SDK restrictions are not a sandbox | [`Apps`](../firmware/lib/nerves_gate/apps.ex), [application model](applications.md) | Trusted app code and ordinary OTP callbacks share the runtime; archive validation is not process/OS isolation. |

## Deferred work

- **Shared-library extraction:** first measure host compile/dependency cost and
  inventory actual reused functions. Components, subscriptions, derived status
  and netlink all need owners; moving structs alone does not sever dependencies.
  Keep the path dependency if that remains simpler.
- **Broader native restoration tests:** add focused failure coverage when a real
  failure demonstrates a missing contract. Loaded modules are not rolled back.
  Do not add generic project-runner machinery or process-isolated repository
  checks without evidence. Device builds and external apps already use isolated
  supervised OS processes.
- **Management access:** settle authentication/exposure before broader deployment.
  The gateway listens on all IPv4 interfaces without user sign-in. CSP, CSRF,
  cellular filtering and USB password recovery do not authenticate LAN/VPN users.
  Trusted-network management access remains a deployment requirement.

## Preserve

- Domain-owned admission, deadlines, rollback and unknown-outcome handling.
- Subscription-before-snapshot ordering and fresh resubscription after owner loss.
- Owned disposable QEMU, private networks and no arbitrary physical/VM attachment.
- Typed SDK observations and caller-owned bus I/O, distinct from admin commands.
- Host asset preparation before isolated target builds, native-port checks and
  shared locked dependencies.
- Separate physical read/review/confirm/write operations; immutable publishing;
  no credentials, cookies or VM identity disks in read models and artifacts.

## Confidence and limits

The boundaries above are source-backed, not inferred from directory names.
Focused host tests cover the session's real service supervisor and moved gateway
checks without starting devices. They do not prove every restart interleaving,
storage failure, upstream behavior or third-party SDK consumer. Full session
startup/reload and device projection checks still require an authorized running
session/bench; see [validation status](refactor-plan.md#validation).
