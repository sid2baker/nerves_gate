# CI

Routine CI never boots a device. Required checks are:

- **checks:** locked dependencies, SDK/simulator/firmware host quality gates and
  root workbench, application, discovery-projection and release-contract tests.
- **firmware-x86_64:** clean root setup, local target firmware build and a musl
  interpreter check for `if_monitor` and `uevent`. No QEMU startup.
- **applications:** create two ordinary external apps against the local SDK,
  test and package both with the ordinary commands. No devices.

Use `applications` instead of the former `solution`/`workspace` check in branch
protection. This repository does not modify protection automatically.

## Native compilation regression

A fresh hosted build once shipped glibc-linked workstation ports into a musl
guest. Guests reached IEx but networking and all host status RPCs timed out.
QEMU version changes did not fix it. Initialization must preserve these boundaries:

1. Firmware code-reload listeners must run only in host/dev.
2. Native root setup must enter the archive's `nerves_bootstrap.init` before
   looking up dependency tasks. Bootstrap aliases are not automatically
   reinstalled when the root enters another project in the same VM.
3. Discard target task-completion state before resolving root host tasks; otherwise
   Nerves tooling compiled in the target graph can be skipped in the host graph.
   Simulator builds select the same local system sources as root setup.

The hosted ordinary suite passed all 41 scenarios after these fixes (run
[39646478170](https://github.com/sid2baker/nerves_gate/actions/runs/39646478170)).
Existing contaminated target build directories require a clean rebuild; changing
initialization does not rebuild every cached native dependency. Root setup and
all device builds are guarded without dropping `--check-locked` or increasing
boot/RPC deadlines. Device compilation always uses a separate OS process.

## Manual integration

`qemu.yml` runs `mix setup` then `mix test.qemu --ci` with disposable owned devices
on Ubuntu 26.04/QEMU 10.2. Portable TCG is used, including on ARM Linux hosts;
KVM availability is reported but is not a requirement. Logs, not VM identity
disks, are retained. The optional Tailscale job is main-only and protected by the
`tailnet-ci` environment. See [tailnet CI](tailnet-ci.md).

Local equivalents:

```sh
mix ci
mix test.qemu --ci --only sdk   # explicit disposable bench, authorization required
```

Ordinary device scenarios also attach to the user's existing session with
`mix test.qemu --only ID [--device ID]`.

## Releases and caches

`release.yml` publishes only SDK Hex releases and asset-free platform GitHub
Releases. System artifacts have their own workflow. Neither is dispatched by
routine CI; see [releases](releases.md).

Host caches include root/subproject dependencies, host builds and firmware PLTs.
Target jobs cache verified downloads and tailscaled input, never compiled target
ports or VM disks. Host tools are installed by
`.github/actions/host-tools/action.yml`; fwup is SHA-pinned.
