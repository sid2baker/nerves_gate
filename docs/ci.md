# CI

Routine CI never boots a device. Required checks:

- **checks:** locked dependencies and root `mix ci` (SDK, firmware and root host
  checks and tests).
- **firmware-x86_64:** clean `mix setup`, a local target firmware build and a check
  that native ports (`if_monitor`, `uevent`) use the musl loader.
- **applications:** create, test and package two external apps against the local SDK.

`qemu.yml` is dispatched manually. It runs `mix setup` and `mix test.qemu --ci` on
disposable devices with portable TCG (KVM is optional), and keeps logs but never
VM identity disks. Its optional, main-only Tailscale job uses the protected
`tailnet-ci` environment; see [tailnet CI](tailnet-ci.md).

`release.yml` publishes SDK Hex releases and platform GitHub Releases; system
artifacts have their own workflows. Neither runs from routine CI. See
[releases](releases.md).

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
