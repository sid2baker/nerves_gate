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

## Distribution boundaries

Initial versions are SDK `0.1.0`, firmware `0.1.0`, simulator `0.1.0` and generator
`0.1.0`. Publish in that order. Generator preflight checks the SDK and simulator's
`~> 0.1.0` release lines before publication.

Firmware's Hex package provides the shared host-side gateway UI used by the
simulator. Its host dependency graph contains only Hex dependencies, including
released LiveView. Unused industrial-protocol dependencies are not platform
services; device apps declare their own private protocol libraries when needed.
Device builds still select their system's Git source and GitHub artifact; host
consumers do not resolve device systems. The release preflight rejects unexpected
Git/path dependencies rather than silently omitting them.

Target-specific `tailscaled` binaries are excluded from the Hex payload. The
firmware release workflow builds a separate x86_64 `.fw` using the published
system, without starting QEMU, and attaches it to the GitHub Release. Workspace
`mix setup` downloads the default image to `firmware/nerves_gate.fw` and verifies
the SHA-256 pinned in the generator. When changing that pin, verify the release
asset's digest and firmware compatibility first. Existing files and custom paths
are preserved. App developers need no GitHub CLI or product source checkout.
This is not a physical-device flash or qualification run.

No packages are published by repository setup, archive smoke tests or ordinary CI.
