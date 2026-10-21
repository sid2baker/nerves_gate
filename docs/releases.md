# Package releases

The SDK, firmware, simulator and generator have independent versions and releases.
Systems use the separate [GitHub system-artifact workflow](development.md#system-artifacts),
not Hex.

## Workflow

`.github/workflows/package-release.yml` runs for these pushed tags:

| Directory | Hex package | Tag |
| --- | --- | --- |
| `sdk/` | `nerves_gate_sdk` | `sdk/v<VERSION>` |
| `firmware/` | `nerves_gate` | `firmware/v<VERSION>` |
| `sim/` | `nerves_gate_sim` | `sim/v<VERSION>` |
| `new/` | `nerves_gate_new` | `new/v<VERSION>` |

Manual dispatch accepts an **existing tag** whose release has not been published.
The tag must resolve to the checked-out commit and that commit must be reachable
from `main`. Protect `main` and the release tag patterns.

Configure the GitHub Environment **`hex-release`** with required reviewers and a
**`HEX_API_KEY`** secret authorized to publish the owned packages. GitHub's built-in
token supplies release permissions; no personal GitHub token is needed. The Hex
key is exposed only to the publication step, never compilation, tests or smoke
checks. Approval starts the job; it does not bypass preflight checks.

For each release:

1. Update the project's `VERSION` and prepare exactly one dated changelog section
   (`## X.Y.Z - YYYY-MM-DD`). Keep `Unreleased` at the top. Review the section as
   public release notes. The workflow rejects missing, empty or duplicate sections.
2. Validate the project and dependency compatibility. Publish SDK before firmware,
   firmware before simulator, and simulator before generator. Generator preflight
   requires compatible SDK and simulator versions on Hex.
3. Commit reviewed sources to `main`, create the matching namespaced tag, and push
   it explicitly. A normal push to `main` does not publish Hex packages.
4. Approve the environment deployment. CI checks dependencies without local-path
   overrides, builds and unpacks the Hex payload, runs package unit tests, and
   compiles/generates docs from the unpacked source. Firmware quality checks belong
   to the repository's CI; its release build compiles host code only.
5. For the generator, CI builds a production archive and installs it in an isolated
   Mix home outside the checkout. It verifies generation, including dotfiles and
   source syntax. This smoke test does **not** boot QEMU or run workspace `mix setup`.
6. After all preflight steps succeed, CI publishes the package and HexDocs, creates
   the GitHub Release, and checks public registry/docs availability and release
   metadata. The generator `.ez` archive is attached to its GitHub Release.

Release title is exactly the tag. Release body is exactly the matching changelog
section body, without its version heading. No generated notes or extra prose.
Prerelease versions produce prerelease GitHub Releases. Releases are not marked
as the repository-wide latest version because this repository has several products.

## Existing and partial releases

CI never uses Hex `--replace` or GitHub `--clobber`. Preflight refuses an existing
Hex version or GitHub Release. A failure after publication can leave partial public
outputs: inspect the package, docs, tag and release before an explicit repair.
Do not rerun blindly, move the tag, or bump a version merely to hide a failed job.
Repair missing docs with `mix hex.publish docs`; repair GitHub metadata/assets
using the same canonical notes and verified archive. Registry propagation checks
are bounded. The workflow keeps preflight package/archive/notes artifacts for 14 days.

## Current first-release prerequisites

Adding the workflow does not mean all packages are ready to publish:

- The SDK's first release is `0.1.0` (`sdk/v0.1.0`), with its dated changelog
  section prepared. Firmware, simulator and generator still need their first
  dated release sections.
- Firmware still has Git dependencies: LiveView's required subscription changes,
  `yaopcua`, `yamodbus`, `s7`, `ethercat`, and the two Nerves systems. Hex cannot
  represent these dependencies; CI explicitly rejects them rather than dropping them.
  Systems intentionally remain Git/GitHub based. Firmware's Hex distribution needs
  a deliberate dependency/package-boundary decision before releasing it.
- The simulator depends on firmware, so it cannot be released successfully before
  firmware has a usable distribution. Generator publication is gated on the SDK and
  simulator being available, even though the generator archive itself can be tested
  locally now.
- Review firmware's package file list before release: ignored target-specific
  `tailscaled` executables can be included through `rootfs_overlay`. Do not publish
  workstation-generated or architecture-inappropriate binaries accidentally.

Resolve these blockers before creating release tags. No packages are published by
repository setup, archive smoke tests or ordinary CI.
