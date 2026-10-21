# Continuous integration

## Routine validation

Pushes and pull requests run `.github/workflows/ci.yml`:

| Job | Checks | Starts devices? |
| --- | --- | --- |
| `checks` | Locked host dependencies and root `mix ci`: SDK, simulator, generator, firmware and private release tools | No |
| `firmware-x86_64` | Build the actual x86_64 firmware, including target-only code and release assembly | No |
| `workspace` | Generate a local-source workspace; setup, test, add a second app, setup again, test, package both apps and check formatting | No |

Host builds and Dialyzer PLTs are cached by toolchain, lockfiles and project files.
The image build caches verified downloads, never VM disks. A cache is an
optimization: locked dependency fetching and all checks still run.

Firmware's host tests cover pure validation, policies and codecs, not hardware.
The workspace smoke job tests current source packages. Isolated archive generation
also runs in the private release-tool tests; package-release preflight verifies
unpacked Hex payloads without repository path overrides. App developers consume
published dependencies, not repository siblings.

Required branch-protection checks should be `checks`, `firmware-x86_64` and
`workspace`. Repository rulesets must be updated by the operator; code changes do
not alter those settings.

## QEMU integration

**QEMU integration** (`qemu.yml`) remains manually dispatched from Actions. It
runs `mix setup` and `mix test.firmware --ci` on disposable GitHub-hosted runners,
including firmware builds and both devices' shared scenarios. Only diagnostic
`.log` files are retained (14 days). Select **tailscale** on `main` to also run
credentialed authentication checks through the protected `tailnet-ci` environment.
See [tailnet CI](tailnet-ci.md).

Both QEMU jobs run on `ubuntu-26.04` (QEMU 10.2). Portable TCG is used,
including on ARM Linux hosts; the runner reports virtualization capabilities.
QEMU 8.2 remains the documented minimum.

The hosted boot/status timeout was reproduced locally with a clean target build.
The cause was a firmware `Phoenix.CodeReloader` Mix listener running on device
targets: native dependencies compiled before Nerves configured its cross-compiler,
producing workstation/glibc executables for the musl guest. Restricting the listener
to host/dev fixes the clean local build and SDK scenario. Hosted verification is
pending. Existing target builds containing host binaries must be removed and
rebuilt; changing the listener does not automatically rebuild their dependencies.
Boot/RPC deadlines were not increased. Manual integration remains the policy.

For an operator-owned standalone run:

```sh
mix test.firmware --ci
```

This boots a disposable bench. Agents must instead use focused checks on the
operator's existing session, and must not start/stop sessions or boot devices
without authorization.

## Publication is separate

**System releases** runs on system-directory changes on `main`, using the shared
**System artifact** publisher. **Package release** runs on namespaced tags.
See [Releases](releases.md). Neither workflow flashes physical devices.

Host-tool installation is shared in `.github/actions/host-tools/action.yml`; fwup
is pinned and checksum-verified. Mix orchestration remains native; shell steps are
limited to host package installation and independent CLI invocations in CI.

Protected environments such as `hex-release` and `tailnet-ci` may be labelled
"deployments" by GitHub. Here they gate publishing credentials or test
authentication, not installation onto physical gateways.
