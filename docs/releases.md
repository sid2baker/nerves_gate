# Package releases

The SDK, firmware, simulator and generator have independent versions and releases.
Systems use the separate [GitHub system-artifact workflow](#system-artifacts),
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
`mix setup` downloads the default image to a versioned path under `firmware/`
and verifies the SHA-256 pinned in the generator, including on subsequent setup
runs. The workspace's default-path expression follows the generator pin on update;
custom paths and older images are preserved. When changing that pin, verify the release
asset's digest and firmware compatibility first. Existing files and custom paths
are preserved. App developers need no GitHub CLI or product source checkout.
This is not a physical-device flash or qualification run.

No packages are published by repository setup, archive smoke tests or ordinary CI.

## System artifacts


Both systems live in this repository. Firmware consumes their source with Git
subdirectory dependencies pinned to `system-ec100/v<VERSION>` or
`system-ec100-qemu/v<VERSION>`. Their `artifact_sites` download fingerprinted
binaries from GitHub Releases in `sid2baker/nerves_gate`; no system Hex packages
are needed. `NERVES_GATE_LOCAL_DEPS=1` selects the checked-out system sources.

1. For build-input changes, bump the system's `VERSION`, update firmware's pinned
   dependency in `firmware/mix.exs`, and add a dated changelog section.
2. Align system dependencies in its `mix.lock` and `firmware/mix.lock`.
3. Push system changes to `main`. The separate `system-releases.yml` workflow
   checks both target releases through `system-artifact.yml`. Current releases
   are reused; missing releases are built, tagged, published and downloaded into
   a fresh cache for verification. EC100 and QEMU publication run independently.

EC100 publication includes the corresponding-source archive and `SHA256SUMS`.
The publisher verifies all required assets and hashes before making a draft
public. Manual dispatch selects `ec100` or `x86_64` and can resume a release.
Release title is exactly the tag; notes are exactly the dated changelog body.

The release tag is read from the system's `artifact_sites`, so downloads and
publication agree. Published tags and assets are immutable; matching releases are
reused. An interrupted draft resumes only with identical sources, locks, toolchain
pins and artifact bytes. Otherwise clean up explicitly or bump the version; never
move a tag or overwrite an artifact.

Local system build (Docker required) and release-plan check (no build, no GitHub):

```sh
cd firmware
export NERVES_GATE_LOCAL_DEPS=1 MIX_TARGET=x86_64 MIX_ENV=dev
mix deps.get
mix nerves.artifact.build nerves_system_ec100_qemu
elixir -r ../tools/lib/artifact_release.ex -S mix nerves.artifact.release plan
```

For EC100, select `MIX_TARGET=ec100` and build `nerves_system_ec100` instead;
collect its sources with
`elixir -r ../systems/nerves_system_ec100/lib/mix/tasks/ec100.release.ex -S mix ec100.release`.
Neither command flashes hardware. Local `plan` is read-only and never publishes.

After changing the QEMU system, the operator resets and starts devices and runs
`mix test.firmware --only system_artifact` against the new system. Release metadata
and immutability checks also run as ordinary simulator unit tests.
