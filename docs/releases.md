# Releases

Platform and SDK publishing is explicit and runs in tag-restricted GitHub
Actions environments. System publishing runs on trusted main-branch source
changes. The workbench owns local release validation but holds no Hex publishing
credential.

## Platform and SDK

| Artifact | Version and notes | Tag | Publication |
| --- | --- | --- | --- |
| Platform (root, firmware, simulator) | Root `VERSION`, `CHANGELOG.md` | `vX.Y.Z` | GitHub Release; no attached assets |
| SDK | `sdk/VERSION`, `sdk/CHANGELOG.md` | `sdk/vX.Y.Z` | Hex, HexDocs and GitHub Release |

The platform is used from a supported checkout. Firmware is built locally from
that checkout. Deploy a tagged or explicitly SHA-identified build: semantic
`firmware` and full `source_revision` are separate public identity fields. Nerves
VCS metadata includes a `-dirty` suffix for modified tracked files. Source-archive
builds must supply both `SOURCE_DATE_EPOCH` and full `SOURCE_REVISION`. Apps declare their required SDK version. No generator archive or
firmware/simulator Hex release is required.

1. Update the relevant version and roll its `Unreleased` changelog into one dated
   `## X.Y.Z - YYYY-MM-DD` section. Firmware and simulator read the root version.
2. Run `mix check`, operator-owned `mix ci`, external/starter application packaging,
   EC100 dev/prod and QEMU target builds. Run appropriate focused QEMU checks on
   the owned bench; before platform publication dispatch the full separate
   integration workflow for the exact main commit to be tagged.
3. Run `mix release.check TAG`. This validates exact version, notes and SDK
   publication dependencies without publishing. A `-dev` version and entries in
   `Unreleased` describe ongoing development, not a releasable tag.
4. Commit and push only when requested, then create/push the immutable tag only
   with release authorization.
5. `.github/workflows/release.yml` validates the tag is on main. For platform tags,
   `release.check integration` requires successful main-branch `ci.yml` and
   `qemu.yml` runs at that exact SHA; missing, cancelled, failed or older runs do
   not qualify. SDK tags use their own SDK/payload checks. The workflow requires outputs
   to be unpublished, publishes the SDK when selected and creates/verifies the
   GitHub Release. SDK publication uses `hex-release`; platform publication uses
   `platform-release` and has no Hex credential.

Configure both environments with selected ref policies: `hex-release` allows
`sdk/v*` tags, `platform-release` allows `v*` tags, and both allow `main` for
manual dispatch of an existing tag. A manually dispatched tag must still point
to a commit on main and pass all publication checks. `HEX_API_KEY` belongs only
to `hex-release`. No required reviewer is configured; approval can be added
separately if desired. `tailnet-ci` is independent and stays main-only.

GitHub Release title is exactly its tag. Its body is exactly the dated changelog
section body, without the heading, generated additions or installation snippets.
Do not replace package bytes, clobber assets, move published tags or automatically
retry a partial publication. Inspect and repair it explicitly.

The workflow uses the same `release.check` task with explicit `prepare`,
`dependencies`, `integration`, `unpublished` and `verify` phases. Its dependency-free preload
allows metadata validation before compiling workstation tooling:

```sh
elixir -r lib/workbench/release.ex -r lib/mix/tasks/release.check.ex -S mix release.check sdk/v0.2.0
```

The current SDK checkout is `0.2.0-dev`, distinct from published `0.1.0`. Local
app templates and the optional subnet-router require `~> 0.2.0-dev`, which
admits this prerelease and future stable 0.2 releases. Use `--local-sdk` until
0.2 is actually published: scaffolding does not fall back to SDK 0.1. At that
separately authorized release, update templates and starter to the stable requirement.
No runtime
capability probe substitutes for the device installer's SDK requirement check.

The platform, SDK, two systems and explicitly selected first-party apps have
separate release streams. Older firmware,
simulator and generator Hex packages remain published; retiring them is a
separate, explicit action.

## First-party applications

First-party apps are ordinary `.ez` assets on this repository's GitHub Releases,
not Hex packages or firmware deployments. The initial approved app is
`tailnet_subrouter`. Its source version and dated `apps/tailnet_subrouter/CHANGELOG.md`
section define tag `apps/tailnet_subrouter/vX.Y.Z`, title and exact release body.
The source may use the checkout SDK prerelease; this does **not** publish that SDK
or claim compatibility with the older Hex SDK. Runtime and exact platform-library
requirements accompany the app archive.

Plan metadata without publishing:

```sh
mix app.release plan apps/tailnet_subrouter/v0.1.0
```

After a separately authorized commit, prepare assets from a **clean committed
checkout**, using a new output directory outside it:

```sh
mix app.release prepare apps/tailnet_subrouter/v0.1.0 --output /tmp/subrouter-release-0.1.0
```

Preparation checks the packaged app/version, pure-BEAM payload, digest/size and
source revision, and writes exactly the `.ez`, schema-1 `.json` manifest and
`release-notes.md`. The manifest records supported targets, OTP major, exact
Elixir, SDK requirement, exact platform versions and source commit. Existing output directories
and release assets are never overwritten. Dirty source is not stamped with an old
HEAD or treated as a release snapshot. Keep the app's lockfile aligned with the
intended firmware's shared libraries. Resolve relevant dependency security
advisories before publication rather than silently changing the target ABI.

`.github/workflows/app-release.yml` publishes only an authorized `apps/*/v*` tag
(or an explicitly dispatched existing tag) at a clean commit on main. It requires
successful routine CI and separate QEMU qualification at **that exact SHA**, tests
the app, audits its dependencies, refuses existing/partial releases, prepares the assets and creates the
GitHub Release once using canonical notes, without replacing the repository's
latest platform release. Verification compares public title,
body, release state and the downloaded asset bytes to the prepared files. It never
clobbers assets, moves a tag, publishes Hex or automatically retries publication.

Configure protected GitHub environment `app-release` to permit `apps/*/v*` tags
and `main` for manual dispatch. It needs only the job's repository token, never a
Hex or device credential. Preparing this workflow is not permission to create its
environment, push commits/tags, publish a release or install it on any gateway.
No app release exists merely because a local archive has been built.

The gateway's Applications page discovers complete first-party releases and owns
review/download/verification/install/upgrade. New installs remain stopped until
explicitly started. Runtime deployment is separate from asset publication. A
private/local artifact with the same version but different bytes is not replaced:
release a new version rather than defeating immutability.

## Systems

Systems remain Git source dependencies with fingerprinted artifacts on GitHub
Releases, not Hex. `systems/` files are artifact inputs: changing them requires a
system version bump, even if the root platform version is unchanged. Do not edit
system source merely to adjust workstation tooling.

`system-releases.yml` calls `system-artifact.yml` for EC100 and QEMU on main when
system paths change. It validates the source contract before creating artifacts.
The task stays dependency-free under `lib/mix/tasks/nerves.artifact.release.ex`
and is preloaded into the isolated firmware/Nerves command:

```sh
cd firmware
MIX_TARGET=x86_64 NERVES_GATE_LOCAL_DEPS=1 elixir -r ../lib/mix/tasks/nerves.artifact.release.ex -S mix nerves.artifact.release plan
```

`plan` is local/read-only. `check` inspects remote publication state; `publish`
requires the authorized main-branch GitHub workflow. Exact notes come from the
system's dated changelog. The system defines the download tag in `artifact_sites`.
Pending source comparison prevents reuse of a tag after fingerprint inputs change;
repairs to the publisher alone do not change system inputs.

Both systems use Nerves 2's explicit `mix nerves.artifact.build`. The shared task
runs Buildroot `make source` before compilation, using Buildroot's configured
mirrors and checksum validation. The Nerves download cache is saved even after
failure. No board-specific downloader or toolchain-source manifest is used.

QEMU needs its fingerprinted binary archive. EC100 also collects Buildroot
`legal-info`, installed external-toolchain notices/configuration, the matching
system/Buildroot recipes and a checksum manifest. See the [source collection
limits](../systems/nerves_system_ec100/SOURCES.md#buildroot-source-and-license-collection):
legal-info does not collect the prebuilt external toolchain's source archives.
Review the reports and arrange any additional required source distribution before
publishing; the archive's existence alone is not proof of compliance.

For local source/license collection, run these current checkout commands from
`firmware/` on Linux with Docker or Podman and an empty `dist/`:

```sh
MIX_TARGET=ec100 NERVES_GATE_LOCAL_DEPS=1 elixir -r ../lib/mix/tasks/nerves.artifact.release.ex -S mix nerves.artifact.release source
MIX_TARGET=ec100 NERVES_GATE_LOCAL_DEPS=1 mix nerves.artifact.build nerves_system_ec100
MIX_TARGET=ec100 NERVES_GATE_LOCAL_DEPS=1 elixir -r ../lib/mix/tasks/nerves.artifact.release.ex -S mix nerves.artifact.release collect
(cd dist && sha256sum --check SHA256SUMS)
```

System documentation such as `SOURCES.md` is itself fingerprinted input and may
contain paths from the tooling used to publish that system. Use the commands above
and the current shared workflow; do not change a published system's inputs merely
to update host helper paths.

Existing uploaded bytes are not replaced. Validate a changed QEMU system with the
owned `system_artifact` scenario before an authorized release. Firmware locks
reference immutable monorepo system tags, never a moving branch. When preparing
firmware alongside a system release, wait for publication before target builds.
