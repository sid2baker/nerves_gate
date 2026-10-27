# Managed plugin lifecycle: invariants and qualification

The lifecycle implementation is shared by firmware-bundled plugins and disposable
SD-backed development artifacts. See [plugin implementation](PLUGIN_IMPLEMENTATION_PLAN.md)
and [runtime](docs/applications.md). Runtime qualification remains pending; host
checks and firmware builds are not proof that device fault paths have been exercised.

## Required invariants

- `NervesGate.Plugins` owns serialized admission, protected generation bindings and
  schema-2 selection metadata. Bounded, authenticated linked workers perform effects
  without blocking status/ownership admission. Unknown worker outcomes block reuse.
- `Plugins.Artifact` verifies immutable `{application, version, sha256}` identities,
  retained archives, complete extracted file trees and reserved application/module
  names. Same-version replacement, digest backfill and automatic adoption are absent.
- Firmware inventory supplies read-only artifacts; development artifacts are SD-backed.
  Neither source bypasses compatibility, namespace, content or ownership validation.
- `Plugins.Loader` preloads verified code, starts private OTP applications, checks
  health and owns one checked unload path. Shared platform libraries are not private
  dependencies and cannot be stopped as part of plugin cleanup.
- A fresh private `{epoch, sequence}` activation binds actual OTP membership, including
  owned dependency processes. SDKBackend and Network fence actual calling PIDs,
  lease references and in-flight effects with this activation. Bus transport proxies
  are removed; Plugins owns exclusive assignment intent and plugin supervision owns
  native handles. Checked whole-plugin stop precedes reassignment. No UI or Task proxy
  becomes the plugin's resource owner.
- Quiescing blocks new ownership/UI admission; checked stop closes real page PIDs,
  stops applications, drains resources and checks code unload. Busy code and uncertain
  cleanup block reuse; there is no force purge or speculative success.
- Rollback is cold activation of the exact previous verified artifact with fresh
  authority. It does not roll back writable plugin data or external device effects.
- Private UI process groups survive manager restart. Sessions also monitor their
  admitting controller and close on its death. Static pages never run plugin code.
- Firmware-selected code does not require SD. Development startup/commit is fenced by
  card/mount identity; removal stops development activations. Bundled plugins that use
  SD data directories must handle unavailable storage and file errors explicitly.
- Saved immutable selections are not silently replaced by a new firmware version.
  Missing selections are reported. Unsupported metadata is left intact and blocks
  admission; no migration, reset, format or uninstall is implied by a source update.

## Existing qualification sources

Host unit/component tests cover artifact tampering, metadata rejection/size limits,
partial preload, actual membership/caller forwarding, private UI admission/drainage,
namespace conflicts, pure-BEAM payload policy and firmware inventory identity.

`lib/scenarios/app_lifecycle.ex`, managed fixture sources and shared cases exercise
real packages and OTP on owned QEMU. The `plugins` case adds no-SD inventory/activation,
UI cleanup and yamodbus TCP. All device cases must use the user's running bench,
per-device reservations and disposable supervised devices.

## Pending runtime qualification

Do not mark these proven until the focused scenarios have actually run:

- Real preload/start/health/commit failures; partial startup and checked rollback.
- Archive/content tampering and immutable version/dependency conflicts.
- Revoked/stale leases, in-flight effects, blocked cleanup and busy code/UI sessions.
- Manager interruption during lifecycle phases and surviving-page closure.
- SD removal/reattachment and storage identity changes during development operations.
- Repeated cold start/stop/restart, firmware version-selection changes and unavailable
  previous artifacts, with no shared-library or unrelated-plugin teardown.
- Durable network ownership recovery and real tailnet route-withdrawal failure.
- Bundled no-SD behavior separately from plugins that require writable SD data.

Physical deployment, storage changes, QEMU lifecycle changes and release publication
require their own authorization. A timeout never authorizes replaying a write.
