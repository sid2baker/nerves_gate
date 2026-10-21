# Releases

Publishing is explicit and occurs in protected CI. The workbench owns local
release validation but holds no Hex publishing credential.

## Platform and SDK

| Artifact | Version and notes | Tag | Publication |
| --- | --- | --- | --- |
| Platform (root, firmware, simulator) | Root `VERSION`, `CHANGELOG.md` | `vX.Y.Z` | GitHub Release; no attached assets |
| SDK | `sdk/VERSION`, `sdk/CHANGELOG.md` | `sdk/vX.Y.Z` | Hex, HexDocs and GitHub Release |

The platform is used from a supported checkout. Firmware is built locally from
that checkout; compatible custom `.fw` files remain usable for cross-version
work. Solutions record their target platform version. No generator archive or
firmware/simulator Hex release is required.

1. Update the relevant version and roll its `Unreleased` changelog into one dated
   `## X.Y.Z - YYYY-MM-DD` section. Firmware and simulator read the root version.
2. Run host checks, the external solution flow, target builds and focused QEMU
   checks appropriate to the change.
3. Run `mix release.check TAG`. This validates exact version, notes and SDK
   publication dependencies without publishing.
4. Commit and push only when requested, then create/push the immutable tag only
   with release authorization.
5. `.github/workflows/release.yml` validates the tag is on main, requires outputs
   to be unpublished, publishes the SDK when selected and creates/verifies the
   GitHub Release. SDK publication uses the protected `hex-release` environment.

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

Previously published firmware, simulator and generator 0.1.x packages remain
immutable and usable by their existing consumers. Retirement is a separate,
authorized action after a replacement platform release exists.

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

QEMU needs its fingerprinted binary archive. EC100 requires its binary archive,
matching source archive and checksum manifest. Existing uploaded bytes are not
replaced. Validate a changed QEMU system with the owned `system_artifact` scenario
before an authorized release. The EC100 0.2.1 artifact is still unpublished.
