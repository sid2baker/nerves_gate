# CI

Routine CI never boots a device. Required checks:

- **checks:** locked dependencies and root `mix ci` (SDK, firmware and root host
  checks and tests).
- **firmware-x86_64:** clean `mix setup`, a local target firmware build and a check
  that native ports (`if_monitor`, `uevent`) use the musl loader.
- **firmware-ec100:** separate dev/prod builds using the locked, fingerprinted system;
  no flashing or booting. Only verified downloads are cached, never native ports.
- **applications:** create, test and package two external apps against the local SDK,
  plus both selected plugin test suites (`plugins/tailnet_subrouter` and `plugins/modbus`).

`qemu.yml` is dispatched manually or runs weekly on Monday at 03:00 UTC on main. It runs `mix setup` and `mix test.qemu --ci` on
disposable devices with portable TCG (KVM is optional), and keeps logs but never
VM identity disks. Its optional, main-only Tailscale job uses the protected
`tailnet-ci` environment; see [tailnet CI](tailnet-ci.md).

`release.yml` publishes SDK Hex releases and platform GitHub Releases; system
artifacts have their own workflows. Neither runs from routine CI. See
[releases](releases.md).

## Local gates and project scope

Run `mix check` at the root before commits. It runs compile/format/tests for root
and SDK, tests the first-party starter, builds shared assets, and runs firmware
compile/format/tests, JS checks, strict credo, zero-clone and architecture/smell
checks. No session or device starts. `mix ci` adds firmware dialyzer and belongs to
the operator; target builds are separate CI jobs. Passing `mix check` is not a
claim that dialyzer, target builds or QEMU passed.

Firmware has the additional static gates because it owns long-lived hardware
workers, admission and persistence. Root changes are checked by host workflow/UI,
release-policy and native-build contract tests; SDK changes by typed API and
package-validation tests. Neither currently has a dialyzer/credo gate. This is an
explicit scope difference, not equal static-analysis coverage; shared firmware
code is still checked under its owning project. Starter apps are ordinary isolated
Mix projects, never loaded into the workbench VM to run their tests.

Platform publishing requires successful `ci.yml` and `qemu.yml` main-branch runs on
**the exact tagged commit**, checked by `release.check integration`. SDK publishing
runs its own SDK/payload checks and does not require QEMU. Weekly integration has
no tailnet credentials unless the separate main-only job is explicitly requested.

## Native target builds

Host-compiled ports in a musl guest break networking and status RPCs while IEx
still starts. Keep these boundaries:

1. Firmware code-reload listeners run only on the host in dev.
2. Root setup runs `nerves_bootstrap.init` before looking up dependency tasks.
3. Root setup clears target task state before running root host tasks.
4. Device builds run in a separate OS process.

Contaminated target build directories need a clean rebuild. Never drop
`--check-locked` or raise boot/RPC deadlines to hide a failure.

## Caches

Host jobs cache dependencies, host builds and firmware PLTs. Target jobs cache
verified downloads and tailscaled input, never compiled target ports or VM disks.
`.github/actions/host-tools/action.yml` installs host tools; fwup is SHA-pinned.
