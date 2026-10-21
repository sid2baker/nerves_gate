# Structure review outcome

This records the decisions and remaining limits from the repository structure
review at `c5c276d`. It is not a new implementation backlog or permission to
publish, change repository settings, or operate physical hardware.

## Ownership and workflow

- Keep independent, non-umbrella Mix projects and native root orchestration.
- Product maintainers use the checkout. App developers use generated workspaces
  and published SDK/simulator/generator packages. Local-source workspaces are
  explicitly for maintainers testing that experience.
- Simulator modules belong to `NervesGateSim` and `NervesGateSimWeb`. The gateway
  remains `NervesGate` / `NervesGateWeb`; the app contract remains `NervesGateSDK`.
- Product scenarios live in `sim/scenarios/`, excluded from the published
  simulator. Private release scripts and their tests live in unpublished `tools/`.
- The shared gateway UI remains in firmware. Its host mode starts only explicitly
  configured host services, never substitute device domains.

## Completed structural changes

| Review items | Outcome |
| --- | --- |
| S1, S2 | Renamed simulator-owned modules/references and moved scenarios into the owning simulator project. Removed cross-project scenario/release-tool compiler paths. |
| S3 | Consolidated package, archive and system release tooling/tests into private `tools/`; root CI checks it. |
| S4 | Documented the shared gateway host-mode contract and distinguished production UI contracts from private recovery/scenario assertions. No new UI package or forwarding layer. |
| S6 | Documented the intentional shared-stylesheet source dependency and rebuilt assets. |
| S7, C1 | Removed redundant `mix check`; root tests and CI include firmware's new hardware-free policy, input-validation and codec tests. Clarified that pure tests are not fake hardware. |
| CI1–CI4 | Added host/PLT caching, a no-boot target firmware-build job, a two-app workspace smoke job, and a shared host-tool action. |
| A1 | Workspace setup checks host tools; errors and generated docs describe Linux installation and the macOS Linux-VM route. |
| A2 | Managed images use a versioned default-path expression and are checksum-verified on reuse and concurrent publication. Custom paths and old versions are never overwritten. |
| A3 | Generated apps demonstrate testable decisions over SDK structs, with no fake backend. |
| A4 | `mix app.console` prints the SSH IEx command for an owned guest only while it has idle Manual ownership. Use RingLogger in that console. |
| A5 | Documented the existing authenticated SSH/SFTP-to-OTP-administration path. No unauthenticated HTTP upload endpoint. |
| A6 | The packager rejects disagreement between dependency and declared SDK ranges. |
| A7 | Split app development and CI into their own guides; moved system release instructions into the release guide. |

The workspace smoke test also exposed and fixed an actual generator regression:
local dependency paths could produce unformatted Elixir files. Generation now
formats Elixir output, with regression coverage for long source paths.

## Explicit product decisions

The operator selected these during implementation:

- **Keep real-gateway deployment SSH-only for now.** Authentication, bootstrap,
  credential recovery and revocation for the gateway HTTP/LiveView UI need a
  separate security design. The current gateway UI is still unauthenticated.
- **Keep independent versions and manual QEMU integration.** Do not introduce
  lockstep releases or schedule the unresolved hosted bench.
- **Do not add live module reload.** Cold app upgrades and normal firmware
  rebuild/restart remain the supported lifecycle.
- Host tests demonstrate pure app logic, not an app-test backend framework.
- Disposable local QEMU validation was authorized for this change. This is not
  standing permission to stop an existing development session or use hardware.

## Corrections to review assumptions

- Renaming simulator modules does **not** remove the root's intentional compiler
  conflict handling. Firmware is compiled both independently and as a simulator
  dependency. Its shared locks, code-path restoration and some clean-build protocol
  consolidation warnings are still relevant.
- Native networking dependencies are not merely unused host baggage. Firmware's
  network technology implements VintageNet behaviours/configuration contracts;
  drivers and recovery code are compiled and statically checked on the host.
  Dropping those dependencies would require separating source/analysis targets or
  weakening checks. Keep the required headers rather than hiding undefined calls
  or making a broad platform split solely to save host installation packages.
- Not all modules labelled "pure" by the review are pure: RouteMetric reads sysfs,
  and Labels also provides disk persistence. Unit tests exercise only the
  effect-free portions; QEMU covers I/O and recovery.
- The firmware pin remains in the workspace tooling, whose version defines the
  workspace default. Simulator packages also support custom firmware; no forced
  simulator/firmware common version or new artifact-manifest service is needed.

## Unresolved external and runtime limits

- **Hosted QEMU boot/status RPC timeout (C3):** read-only inspection of run
  `39560927723` confirms guests reach IEx but host status calls time out. This is
  not evidence of a KVM-only problem. Boot failures now record bounded domain
  liveness/current-function diagnostics separately from the status call, and the
  workflow reports virtualization capabilities. A new hosted run is still needed
  to diagnose and verify a fix. Deadlines were not increased.
- **MuonTrap output race:** host tests exposed an existing short-lived-command
  `:epipe` race. A trial exit-trapping change could hang and was removed. Do not
  describe a later passing run as fixing that dependency/runtime race.
- **EC100 system 0.2.1 (R1)** is still unpublished, confirmed through the GitHub
  release API. Publication requires an explicit release request; no workflow was
  dispatched and no published version/tag was modified.
- **Package releases (R3)** remain pending. Changes are in Unreleased changelog
  sections. No package was published and no version/tag was changed.
- **Branch protection (CI6):** the operator must require `checks`,
  `firmware-x86_64` and `workspace` in repository rulesets. Local workflow changes
  do not change GitHub settings.
- Ignored `ec100-backups/` and `tmp/` remain untouched. Move sensitive backups to
  an operator-owned location outside the checkout; never include them in payloads
  or CI artifacts.

## Validation

Completed for this change:

- Root `mix ci`: SDK **11**, simulator **15**, generator **13**, firmware **7**
  and private tools **5** tests passed. Firmware static checks and Dialyzer passed.
- The same locked dependency fetch and root CI passed from a fresh source snapshot,
  without existing dependencies or build products. This exposed a stale
  `nerves_time` lock; both shared locks were deliberately updated to **0.4.14**
  (upstream's invalid-RTC-time fix). `--check-locked` remains enforced.
- Actionlint and `git diff --check` passed.
- Generated local-source workspace: setup, tests, a second app, setup again,
  tests, packaging both apps and format checking passed without starting devices.
- Frontend assets rebuilt and JavaScript checks passed.
- Authorized disposable QEMU checks passed: `sdk`, `system_artifact`,
  `test_bench`, `frontend_assets`, `apps` and `storage`. The SDK and system
  contract checks were repeated after the final lock update; the real x86_64
  firmware build passed too.

These checks do not qualify physical hardware, authenticate the current gateway
UI, prove a hosted QEMU fix, or publish any package. The full scenario suite was
not run. No existing development session was stopped or reset.
