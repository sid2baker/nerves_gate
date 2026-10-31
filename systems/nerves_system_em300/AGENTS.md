# AGENTS.md

## Goal

Build a working, reproducible Nerves system for the real hardware.

Keep it stupidly simple.

## Principles

- Hardware first. A change is useful only if it helps the real board build, boot, update, or recover.
- Prefer the smallest working solution.
- Make one change at a time and test it on hardware.
- Do not add abstractions, frameworks, compatibility layers, or future-proofing unless they are required now.
- Prefer source-built components over copied vendor artifacts when practical.
- Keep vendor-specific behavior isolated and documented.
- Preserve a known-good boot path while replacing components incrementally.
- Fail early and loudly when assumptions are wrong.
- Keep factory flashing and recovery simple and repeatable.
- Bump the system version when build artifacts change, except during `-dev` iteration. Keep the same `-dev` version while iterating; Nerves artifact fingerprints distinguish builds.

## Priorities

1. Boot the board reliably.
2. Mount the correct Nerves root filesystem.
3. Support networking and required hardware.
4. Make factory provisioning reproducible.
5. Make A/B firmware upgrades and rollback reliable.
6. Replace remaining vendor artifacts with source-built equivalents.

## Working Style

Before changing code:

- Read the current implementation.
- Confirm the hardware behavior from logs or direct testing.
- Choose the smallest change that can prove the next assumption.

After changing code:

- Build it.
- Test it on the EM300.
- Record the exact failure if it does not work.
- Fix the observed problem, not hypothetical ones.

Do not refactor working hardware code while bring-up is still in progress.

## Monorepo releases

This system lives in the Nerves Gate monorepo with its own VERSION and CHANGELOG.
Monorepo releases will use `system-em300/vX.Y.Z` tags in `sid2baker/nerves_gate`.
The EM300 is not yet part of `.github/workflows/system-artifact.yml`; add it only
when a release is requested. Never overwrite published tags or assets. Bump VERSION and update the changelog
and firmware's pinned dependency for build-input changes, including artifact-site
or package-file changes. Keep the system lock aligned with firmware's build tools.
