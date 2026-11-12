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
builds must supply both `SOURCE_DATE_EPOCH` and full `SOURCE_REVISION`. Plugins declare their required SDK version. No generator archive or
firmware/simulator Hex release is required.

1. Update the relevant version and roll its `Unreleased` changelog into one dated
   `## X.Y.Z - YYYY-MM-DD` section. Firmware and simulator read the root version.
2. Run `mix check`, operator-owned `mix ci`, generated-plugin and plugin packaging,
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
plugin templates and the optional subnet-router require `~> 0.2.0-dev`, which
admits this prerelease and future stable 0.2 releases. Use `--local-sdk` until
0.2 is actually published: scaffolding does not fall back to SDK 0.1. At that
separately authorized release, update templates and plugins to the stable requirement.
No runtime
capability probe substitutes for the device installer's SDK requirement check.

The platform, SDK and each system have separate release streams. Selected plugins
and their dependency closures ship with platform firmware. Older firmware,
simulator and generator Hex packages remain published; retiring them is a
separate, explicit action.

## Bundled plugins

`plugins/selection.exs` selects independent pure-BEAM plugin projects. Firmware
assembly builds their dependency closures, validates compatibility/conflicts and
includes a verified read-only inventory. Plugins and their libraries are delivered
and updated through firmware, not separate GitHub releases or a device store.
Keep plugin versions and lockfiles aligned with the selected firmware. Changed
bytes require a new plugin version; saved immutable identities are not overwritten.
See [plugin runtime](plugins.md) and [development](plugin-development.md).

## Systems

Systems are Git source dependencies with fingerprinted artifacts on GitHub
Releases, not Hex. Physical systems are maintained separately:

- [EC100](https://github.com/sid2baker/nerves_system_ec100)
- [EM300](https://github.com/sid2baker/nerves_system_em300)

Both use the official `actions-nerves2-package` build/draft-release workflow and
`vX.Y.Z` tags. Follow each system's README for release preparation, including
reviewing and committing `checksum.exs` before tagging for Git consumers. Publishing
a draft is manual. Review Buildroot notices and corresponding-source obligations
before distribution; the standard artifact does not include source archives.

Firmware retains EC100's published `system-ec100/v0.4.0` pin until the standalone
`v0.5.0` artifact is published. EM300 pins its standalone bring-up commit and needs
an explicit local artifact build before firmware can be packaged. See
[development](development.md#assets) for checkout overrides.

### Owned QEMU system

`systems/nerves_system_ec100_qemu/` remains in this repository. Its source,
version and release model are unchanged. `system-releases.yml` calls
`system-artifact.yml` only for QEMU changes on main. The dependency-free publisher
is preloaded into an isolated firmware/Nerves command:

```sh
cd firmware
MIX_TARGET=x86_64 NERVES_GATE_LOCAL_DEPS=1 elixir -r ../lib/mix/tasks/nerves.artifact.release.ex -S mix nerves.artifact.release plan
```

`plan` is local/read-only. `source` prefetches through Buildroot. `check` inspects
publication state; `publish` requires the authorized main-branch GitHub workflow.
Notes and the download tag come from the system. Existing uploaded bytes are never
replaced. Lock alignment and pending-input checks remain mandatory. Validate a
changed QEMU system with the owned `system_artifact` scenario before an authorized
release. Physical systems are rejected by this publisher.
