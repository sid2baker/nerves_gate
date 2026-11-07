# Gate rules

Load this file for `focus:gates` or when a configured gate reports one of these
causes.

## Gate failure router

`gate-failure-router` version 1 is intake only. Inspect the failed command and
route each root cause to the most specific rule below or another surface rule.
Do not create a router backlog row. When no built-in owns the cause, define a
project-prefixed rule before recording it.

## `format-drift` version 1

- **Use when:** The project has an Elixir formatter configuration.
- **Detect:** Run the configured format check.
- **Finding:** Accepted source or test paths differ from required format.
- **Fix:** Format only accepted paths.
- **Protect:** Source meaning and unrelated changes.
- **Verify:** The format check passes and the diff has only expected changes.
- **Judgment stop:** Formatting would absorb unrelated or unsupported files.
- **Batch key:** Formatter scope.

## `compile-warning` version 1

- **Use when:** The project can compile in the required environment.
- **Detect:** Compile with the project's warning policy.
- **Finding:** One warning root cause in owned code or test support.
- **Fix:** Correct the source contract instead of hiding the warning.
- **Protect:** Behavior, supported versions, and public contracts.
- **Verify:** Warning-as-error compilation and focused tests pass.
- **Judgment stop:** A dependency, version, or public API choice is required.
- **Batch key:** Compiler boundary and affected tests.

## `credo-finding` version 2

- **Use when:** Credo or a compatible configured lint gate is present.
- **Detect:** Run the configured command and priority policy. Separate required
  failures, new regressions, and existing advisory output. Record a configured
  count or threshold when it is the comparable baseline.
- **Finding:** One lint root cause, grouped across repeated messages.
- **Fix:** Apply the smallest source correction.
- **Protect:** Behavior, clarity, and enabled-check policy.
- **Verify:** The focused finding is absent and the lint gate passes.
- **Judgment stop:** The change disables a rule, adds an ignore, or changes a
  deliberate design.
- **Batch key:** Check ID and subsystem.

## `dialyzer-warning` version 1

- **Use when:** Dialyzer is configured and its PLT can run.
- **Detect:** Run the configured command and unused-filter check when available.
- **Finding:** One type-contract root cause or stale ignore entry.
- **Fix:** Correct types or code; remove a stale ignore after proof.
- **Protect:** Runtime behavior, callbacks, and supported dependencies.
- **Verify:** The warning is gone and the configured Dialyzer gate passes.
- **Judgment stop:** The change adds an ignore, changes a public type, or accepts
  an external defect.
- **Batch key:** Type boundary and gate.

## `documentation-gap` version 1

- **Use when:** MixDoctor, ExDoc warnings, or another documentation policy is
  configured.
- **Detect:** Run the configured documentation check.
- **Finding:** One undocumented or inconsistent public contract.
- **Fix:** Document actual behavior or mark a true internal module with the
  project's convention.
- **Protect:** Public behavior and API visibility.
- **Verify:** The documentation gate and applicable examples pass.
- **Judgment stop:** Public versus internal ownership is unclear.
- **Batch key:** Public module or documentation section.

## `quality-contract-drift` version 1

- **Use when:** A project has a normative quality manifest for suites, owners,
  thresholds, artifacts, waivers, or component proof.
- **Detect:** Run the manifest validator and compare registered modules, suites,
  owners, and artifacts with the current package.
- **Finding:** One required quality surface is missing, stale, unowned, or no
  longer matches the package.
- **Fix:** Reconcile the manifest with an established owner and policy. Do not
  lower a threshold or exclude a surface as a mechanical fix.
- **Protect:** Required suites, thresholds, owners, evidence paths, and waiver
  policy.
- **Verify:** The contract validator and each affected quality command pass.
- **Judgment stop:** Ownership, applicability, or threshold policy must change.
- **Batch key:** Contract section and owner.

## `stale-waiver-or-ignore` version 1

- **Use when:** The project stores warning ignores, test exclusions, waivers, or
  baseline exceptions.
- **Detect:** Run the configured unused-entry check and inspect owner, reason,
  expiry, and resolution condition.
- **Finding:** One exception is expired, unused, incomplete, or masks a different
  current cause.
- **Fix:** Remove a stale entry or update it only through the project's waiver
  policy with current evidence.
- **Protect:** The original finding, current gate, ownership, and audit history.
- **Verify:** The gate passes without the stale entry and no original failure is
  hidden.
- **Judgment stop:** Renewing or broadening an exception is required.
- **Batch key:** Waiver registry and finding ID.

## `unused-dependency` version 1

- **Use when:** A configured dependency check or source inspection identifies a
  direct dependency with no supported use.
- **Detect:** Check compile, runtime, configuration, Mix tasks, protocols,
  optional features, docs examples, and release paths.
- **Finding:** One direct dependency has no supported consumer in its declared
  environments.
- **Fix:** Remove the dependency and obsolete configuration or integration code.
- **Protect:** Optional features, supported environments, package contents, and
  downstream compilation.
- **Verify:** Dependency, compile, test, and package checks pass in affected
  environments.
- **Judgment stop:** Downstream, optional, or release-time use remains possible.
- **Batch key:** Dependency and environment set.

## `package-artifact-drift` version 1

- **Use when:** The project builds a Hex package, release, archive, or another
  declared distribution artifact.
- **Detect:** Inspect the configured build and resulting file manifest, metadata,
  documentation, licenses, and excluded private files.
- **Finding:** One required file or metadata item is missing, or one unsupported
  or sensitive file is included.
- **Fix:** Correct the owning package configuration or source path.
- **Protect:** Runtime files, documentation, licenses, source links, and secrets.
- **Verify:** Build and inspect the artifact, then run its supported smoke check.
- **Judgment stop:** Public distribution contents or compatibility are not
  established.
- **Batch key:** Artifact type and manifest entry.
