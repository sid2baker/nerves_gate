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
that checkout. Apps declare their required SDK version. No generator archive or
firmware/simulator Hex release is required.

1. Update the relevant version and roll its `Unreleased` changelog into one dated
   `## X.Y.Z - YYYY-MM-DD` section. Firmware and simulator read the root version.
2. Run host checks, the external application flow, target builds and focused QEMU
   checks appropriate to the change.
3. Run `mix release.check TAG`. This validates exact version, notes and SDK
   publication dependencies without publishing.
4. Commit and push only when requested, then create/push the immutable tag only
   with release authorization.
5. `.github/workflows/release.yml` validates the tag is on main, requires outputs
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
`dependencies`, `unpublished` and `verify` phases. Its dependency-free preload
allows metadata validation before compiling workstation tooling:

```sh
elixir -r lib/dev/release.ex -r lib/mix/tasks/release.check.ex -S mix release.check sdk/v0.1.0
```

Only the platform, SDK and two systems receive new releases. Obsolete component
and legacy QEMU GitHub releases/tags have been removed; source history remains
reachable through the commits linked in the root changelog. The standalone EC100
repository is archived and points here. Previously published firmware, simulator
and generator Hex packages still exist. Retiring them is a separate action after
a replacement platform release exists; the SDK remains active.

## Systems

Systems remain Git source dependencies with fingerprinted artifacts on GitHub
Releases, not Hex. `systems/` files are artifact inputs: changing them requires a
system version bump, even if the root platform version is unchanged. Do not edit
system source merely to adjust workstation tooling.

`system-releases.yml` calls `system-artifact.yml` for EC100 and QEMU on main when
system paths change. It validates the source contract before creating artifacts.
The task stays dependency-free under `lib/dev/artifact_release.ex` and is preloaded
into the isolated firmware/Nerves command:

```sh
cd firmware
MIX_TARGET=x86_64 NERVES_GATE_LOCAL_DEPS=1 elixir -r ../lib/dev/artifact_release.ex -S mix nerves.artifact.release plan
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

Existing uploaded bytes are not replaced. Validate a changed QEMU system with the
owned `system_artifact` scenario before an authorized release. Firmware locks
reference immutable monorepo system tags, never a moving branch. When preparing
firmware alongside a system release, wait for publication before target builds.
