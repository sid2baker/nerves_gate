# Reliability implementation plan

## Goal

With valid enrollment and access policy, once power and required external services
return, the gateway must become remotely usable within a defined deadline. It must
preserve its identity and confirmed settings without an operator restarting it.

A passing test proves useful access from another tailnet device, not just a healthy
status map or a new process PID. Permanent hardware/storage failure, revoked access
and an ongoing Internet outage cannot be fixed by rebooting.

## Keep it simple

- Keep `spec/0`, `run/1`, `test/scenarios/` and the shared UI/CLI/CI runner.
- Add small drivers for remote access, browser actions and missing faults.
- Use ordinary Elixir steps and assertions, not a scenario language or chaos platform.
- Test production recovery. Test cleanup is never counted as device recovery.
- Restart the smallest appropriate component. Never use factory reset as recovery.
- Improve production behavior only when a concrete scenario demonstrates a gap.

## Implemented slice: local process crashes

`process_crash` and `test/support/recovery_checks.ex` now exercise eight supervised
gateway children: SSH settings, Network, Remote, Equipment, Indicators, Buses,
ProjectionServer and Endpoint. Workers are killed without cleanup. The Endpoint
supervisor fails as OTP supervisors do: it stops its children, then exits
`:shutdown`. Killing a supervisor brutally orphans its named children, which then
race its immediate restart (`already_started`); OTP never fails that way itself, so
that fault is not injected. Each recovery must preserve the kernel/BEAM boot
identity, confirmed network settings, a scenario-added SSH key fingerprint and
public remote identity fields. The actual supervisor startup order determines
which `rest_for_one` children must restart and which must stay unchanged.

The initial local budget is 30 seconds including five seconds of stable repeated
fresh HTTP requests and domain queries. `recovery.log` records host monotonic times,
actual/expected restart scope, observed outage and recovery/stability durations.
Two negative controls reject unchanged PIDs and a stopped HTTP listener; restoring
that listener is explicitly probe validation, not autonomous device recovery.
The runner records the original failure and bounded boot/process diagnostics
before cleanup, keeping its timeout active until cleanup completes. Diagnostics
also retain fixed logger error tags, never raw log messages or process state.

**Gap found and fixed:** a QEMU device that stayed up for 15 minutes rebooted.
The QEMU system's fwup tasks never set `nerves_fw_validated`, so
`Nerves.Runtime.StartupGuard` could not read a validation status and its Heart
callback rebooted the guest. System 0.2.1 marks complete installs valid and
upgrades unvalidated until the guard validates them. `system_artifact` and
`firmware_upgrade` require the guard to finish. EC100's U-Boot bootcount
variables already supplied a status.

This is **private-management coverage only**. It does not prove SSH host identity,
enrollment durability, access through Tailscale, LiveView browser recovery, hang
recovery or watchdog behavior. The independent remote client and credentialed
checks remain pending; no auth key is required for this slice. Unchecked items
below retain their full end-to-end meaning.

## 1. Define recovery and preserve evidence

Main files: `test/support/runner.ex`, `test/support/qemu.ex`,
`test/support/scenario_helpers.ex`.

- [ ] Establish a healthy baseline before injecting a fault. If the remote client or
  required external service is unhealthy, fail setup rather than blaming the gateway.
- [ ] Measure fault time, observed outage, recovery time and a post-recovery stability
  window using host monotonic time. Bound every probe and operation.
- [ ] Record device boot identity, expected restart scope, settings, SSH host identity
  and tailnet identity. Never record private keys, cookies or login URLs.
- [ ] Define initial budgets for component recovery, daemon recovery and reboot plus
  reconnection. Measure healthy runs before fixing thresholds. Exclude deliberate
  power/network downtime from the post-restoration recovery budget.
- [ ] Verify repeated fresh connections and a useful operation, not one successful
  ping, an existing connection or a cached page.
- [x] Mark failure before any harness rescue. Capture bounded diagnostics before
  clearing faults, rebooting or replacing disks; cleanup cannot change a failed
  result to passed. Diagnostic failure must not hide the original failure.
- [ ] Preserve the existing fail-closed behavior after uncertain control outcomes.
  Expected loss of the device's network is not itself an uncertain harness command.

**Done when:** a deliberately unrecovered device fails with a useful timeline,
and subsequent cleanup cannot hide that failure.

## 2. Add an independent remote client

Main files: `dev/simulator.ex`, `dev/simulator/`, `dev/simulator.exs`,
`test/support/`; extend session configuration only as needed.

- [ ] Add a simulator-owned, disposable remote-client peer on the private bench
  networks, enrolled in an isolated test tailnet. Reuse the owned-device machinery.
- [ ] Keep the observer separate from the devices under test. Normal target fault
  selection and fresh-disk cleanup must not kill it or erase its enrollment.
- [ ] Provision only test identities with narrowly scoped policy. Define enrollment,
  expiry and removal of owned test peers, including failure cleanup.
- [ ] Supply credentials at runtime; never store them in simulator configuration,
  projections, API snapshots, logs or artifacts. Do not reuse workstation identity.
- [ ] Run fresh SSH and HTTP/HTTPS requests from that peer to the gateway's tailnet
  address/name. Verify SSH host identity and TLS certificates where HTTPS is used.
- [ ] Observe the real DNS and connection path. Prove that private management
  forwards cannot accidentally satisfy a remote-access assertion.
- [ ] Keep the private management connection for injection and diagnostics only.
- [ ] Make local-only and enrolled-remote selections explicit in UI, CLI and CI,
  using the same runner. Missing prerequisites fail a requested remote run before
  mutations; excluded remote coverage must not appear as passed.

**First scenario:** enroll once, establish remote access, crash `tailscaled`, and
require fresh remote SSH and HTTPS access without another login or test rescue.

**Done when:** breaking only the tailnet path fails the remote scenario even while
private QEMU management remains healthy.

## 3. Exercise real user journeys in a browser

Main files: a small Elixir browser driver in `test/support/`, shared scenarios,
`dev/setup.exs`, and the CI prerequisite steps.

- [ ] Choose an Elixir-controlled WebDriver browser. Supervise the browser/driver
  processes; keep scenario logic and tooling in Elixir.
- [ ] Route its gateway traffic, including DNS, through the remote-client peer using
  an explicit restricted proxy. Do not change workstation routes or VPN settings.
  Reject fallback paths that bypass the peer.
- [ ] Verify the chosen browser/proxy combination actually uses that path before
  adding the rest of the journeys.
- [ ] Use stable accessible names or element IDs and condition-based waits.
- [ ] Configure a gateway through supported UI flows: network setup/confirmation,
  SSH key management and Tailscale connection. Keep one-time enrollment separate
  from scenarios that must prove enrollment survives.
- [ ] Test network rollback after browser loss, browser reload during a trial, and
  reconnection after a service restart or device reboot.
- [ ] Perform an action after reconnect and observe updated device state. An HTTP
  200 alone does not prove LiveView/WebSocket functionality.
- [ ] Keep focused API/render checks for diagnosis. Browser journeys run through
  the same scenario runner, not a second suite implementation.
- [ ] Allow only sanitized browser diagnostics. Never capture private login dialogs,
  distribution cookies, auth-key inputs or secret-bearing browser state.

**Done when:** an enrolled remote browser completes a useful workflow, loses its
connection during an injected fault, and completes another action after recovery.

## 4. Add deterministic process crash and hang scenarios

Main files: `test/support/qemu.ex`, `dev/simulator/device.ex`,
`dev/simulator/qemu.ex`, and new modules in `test/scenarios/`.

- [ ] Start with an explicit target list: gateway domains, projection, endpoint,
  relevant VintageNet processes and the supervised Tailscale daemon.
- [ ] Resolve targets in the selected owned guest immediately before injection.
  Record the target and guest boot identity; never accept arbitrary host PIDs.
- [ ] Declare the expected restart scope from the actual supervision tree, including
  legitimate `rest_for_one` dependent restarts. Do not require every PID to stay put.
- [ ] Kill processes without graceful shutdown and check useful service restoration,
  persistence, remote access, restart scope and stability.
- [ ] Separately suspend critical processes or stop the daemon so it remains alive
  but unresponsive. A crash test is not a hang test.
- [ ] Inject faults while idle and during network trials, confirmed saves, remote
  operations and browser requests. Never blindly replay ambiguous user commands.
- [ ] Keep fault entry points host-only and scoped to runner reservations. Do not
  add production HTTP fault controls or weaken backend admission.
- [ ] Add deliberate restart-intensity cases after isolated failures pass.

**Done when:** every initial target has a deterministic crash case and every
remote-critical component has an explicit hang expectation. Failures identify
which production recovery mechanism is missing.

## 5. Test and close production recovery gaps

Main files: the affected domains under `lib/nerves_gate/`,
`config/firmware.exs`, `rel/vm.args.eex`, and both Nerves systems where required.

- [ ] Retain domain-owned deadlines and ordinary supervision. Do not add a global
  command coordinator or a broad connectivity-triggered reboot loop.
- [ ] For demonstrated hangs, add the smallest bounded progress check at the correct
  owner. Define recovery escalation and rate limits; do not treat mere PID existence
  as progress.
- [ ] Verify recovery restores saved intent and enrollment. An intentional Tailscale
  disconnect must remain disconnected; revoked/expired access must remain visible
  rather than cause login attempts or reboots forever.
- [ ] Verify boot startup guarding and ongoing Heart behavior separately. Coordinate
  callback ownership with Nerves Runtime's startup guard; keep Heart callbacks tiny,
  bounded and free of network I/O.
- [ ] Add a real QEMU watchdog and matching system driver so the same firmware Heart
  path can be tested. Publish changed system inputs under a new system version.
- [ ] Stop the guest BEAM while the guest OS/watchdog continues running. Require
  watchdog-driven recovery and remote reconnection without a harness resume/reboot.
- [ ] Test startup hangs and repeated failed recovery. Bound restart storms while
  retaining as much diagnostics and local recovery access as the failure permits.
- [ ] Keep whole-VM pause as a separate isolation test: pausing QEMU can pause the
  virtual watchdog too, so it is not proof of BEAM watchdog recovery.

**Done when:** component crashes recover at their intended scope, demonstrated
hangs have a bounded response, and a stopped BEAM recovers through the real watchdog
path. EC100 watchdog qualification remains a separate hardware gate.

## 6. Cover network and dependency failures

Extend `internet`, `latency`, `loss`, `topology` and add focused remote scenarios.

- [ ] Test cable loss, carrier-up Internet blackholes, severe loss, latency, DNS
  failure and address/route changes. Preserve the real protocol paths.
- [ ] Hold outages long enough to expose retry exhaustion and reboot loops. Require
  recovery after restoration, not remote reachability while the uplink is absent.
- [ ] Test Tailscale daemon loss separately from unavailable DNS, control services
  and relay/direct transport paths. Verify injected faults affect the intended path.
- [ ] Retain an independent peer/control observation so test-infrastructure failure
  is distinguishable from gateway failure. Report genuine dependency failures.
- [ ] Verify equipment-port failure does not unnecessarily disrupt remote management.
- [ ] Test intentional disconnect, expired/revoked credentials and access-policy
  denial as different outcomes from an accidental service failure.
- [ ] Check that unrelated network settings, enrollment and keys remain unchanged.

**Done when:** each recoverable outage restores real remote operations, while
intentional or authorization-related unavailability produces no recovery storm.

## 7. Cover power, storage and firmware interruption

Extend `power_saved`, `power_trial`, `storage`, `storage_reboot`, `ssh_access`
and `firmware_upgrade` with the same external success checks.

- [ ] Separate power-off and power-on controls so outage duration is explicit and
  disks are preserved. Resume power as the external event; do not replace the disk
  to manufacture recovery.
- [ ] Cut power during idle operation, a pending trial, confirmed-setting writes,
  SSH-key changes and Tailscale identity updates. Assert each operation's actual
  durability contract; do not assume multi-file persistence is transactional.
- [ ] Use observable operation stages and recorded offsets, rather than sleeps that
  merely hope to interrupt a critical write.
- [ ] Add disk-full and read-only cases alongside existing EIO injection. Never
  report an unsaved change as confirmed; check predictable boot/recovery behavior.
- [ ] Interrupt firmware transfer, image installation and first boot separately.
  Test valid cross-version upgrades, not only repeated uploads of the same image.
- [ ] Define and verify boot validation/rollback behavior. A successful application
  startup alone is not remote-access proof; an external outage alone must not
  misclassify good firmware. Implement any bootloader changes explicitly.
- [ ] Verify SSH host keys, tailnet identity, confirmed settings and usable remote
  access after recoverable interruptions. Keep failures and unsupported cases visible.
- [ ] Document the fidelity limit: killing QEMU retains host caches and does not
  reproduce physical flash power loss or EC100's U-Boot behavior.

**Done when:** supported interruption points either restore usable access or follow
the documented rollback/recovery path, without silent data-loss claims.

## 8. Add seeded chaos and soak runs

Build these from the deterministic faults above, not a separate chaos engine.

- [ ] Add one process-chaos scenario with a seed and bounded iteration count.
  Start with one fault, wait for verified stable recovery, then choose the next.
- [ ] Record the seed, firmware/system versions, actual selected targets and event
  sequence. A seed repeats choices; it cannot guarantee identical concurrent timing.
- [ ] Support replaying the recorded action sequence using the same drivers.
- [ ] Stop on the first invariant violation; collect diagnostics before cleanup.
- [ ] Run faults during ordinary browser/SSH workloads, not just on idle devices.
- [ ] Add selected overlapping faults only after single-fault coverage passes:
  Internet loss plus reboot, daemon crash during a trial, and power loss during an
  update. Reserve all affected devices and the shared observer.
- [ ] Add explicit-duration soak runs with recovery/restart counts and resource-trend
  checks: memory, process/port counts, descriptors and disk growth. Keep the runner's
  own deadlines and logs bounded; never disable timeouts globally.

**Done when:** a failing run yields a useful replay sequence, no test rescue can
produce a pass, and repeated recovery does not steadily leak resources.

## 9. Integrate reporting, CI and hardware qualification

Main files: `dev/simulator_web/`, `dev/mix/tasks/qemu.test.ex`,
`dev/qemu_session.exs`, `.github/workflows/` and `docs/development.md`.

- [ ] Show selected coverage, prerequisites, phase, fault, seed and recovery duration
  on the device page and CLI. Keep one backend admission path.
- [ ] Reserve the observer for remote scenarios; use existing all-device exclusivity
  initially rather than adding a generic resource scheduler.
- [ ] Gate normal CI with bounded deterministic local scenarios. Add explicit
  credentialed remote checks before treating remote reliability as qualified.
- [ ] Run a short fixed-seed chaos selection in the appropriate CI job. Put longer
  varied-seed/soak runs on scheduled or operator-requested jobs using the same runner.
- [ ] Provision CI identities securely, restrict access to trusted jobs, clean up
  only owned peers and never expose credentials to untrusted PR code. Report remote
  coverage as not run where credentials are deliberately unavailable.
- [ ] Retain sanitized timelines, console logs, restart evidence and browser failures.
  Do not upload disks, credentials, raw secret-bearing state or unsanitized pages.
- [ ] Separately qualify real EC100 power interruption, watchdog/kernel hangs,
  flash persistence and bootloader rollback on an explicitly authorized lab bench.
  Never attach the QEMU drivers to physical or arbitrary devices.

**Done when:** CI clearly distinguishes local, remote and soak coverage, and QEMU
results are not presented as qualification of untested physical behavior.

## Validation and delivery order

Implement in small, reviewable slices:

1. Recovery assertions/evidence and the independent remote client.
2. One end-to-end `tailscaled` crash/reconnect scenario.
3. Browser journeys and deterministic process crash/hang coverage.
4. Production fixes driven by failures, including virtual-watchdog qualification.
5. Network/dependency, storage, power and update interruption cases.
6. Seeded chaos, soak runs and release qualification gates.

For each slice, format and run the relevant static checks, then focused scenarios
on the operator's existing session. Confirm the negative case too: a broken remote
path or disabled recovery must actually fail the new assertion. The user owns
session restarts, device boot authorization and full `mix ci`; this plan authorizes
no physical flashing, workstation networking changes or destructive lab actions.
