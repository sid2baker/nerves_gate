# Plugin runtime

Plugins are trusted ordinary OTP applications in the gateway's BEAM, not sandboxed
services. They can crash/block the VM and share its global application/module
namespace. There is one lifecycle manager: `NervesGate.Plugins`.

## Installation and discovery

`plugins/selection.exs` explicitly selects independent plugin projects. Root
`mix firmware x86_64` or `mix firmware ec100` builds them in isolated host Mix
processes, validates the complete selection and includes immutable artifacts under
the firmware application's `priv/plugins`. A build-generated `inventory.term`
identifies entry points, versions, dependency/module reservations and digests.
The manager reads that inventory, not arbitrary directories or loaded OTP apps.
Libraries are dependencies, not separately discovered plugins.

Add/update/remove bundled plugin code by changing the selection, sources or
lockfiles and rebuilding firmware. There is no GitHub app catalogue, device-side
package resolution, download service or independent plugin update. Firmware-owned
artifacts cannot be overwritten or uninstalled from the running device.

The initial selection contains:

- `tailnet_subrouter`: claims a free LAN exclusively assigned to it under Hardware
  and optionally advertises its subnet through the platform's existing Tailscale.
- `modbus_plugin`: uses [yamodbus](https://github.com/tallakt/yamodbus) for read-only
  Modbus TCP/RTU holding/input register polling. RTU requires enabled exclusive RS485
  assignment and explicit operator approval; no register writes or automatic discovery.
  Configuration and connection are explicit, separate actions.

New plugins are stopped/disabled. Starting them starts their supervision trees;
it does not configure Ethernet, advertise routes or connect to equipment. Saved
started intent can be restored after reboot, but these two plugins deliberately
forget their volatile equipment/sharing configuration and require explicit action.

## Dependencies

Each project declares and locks its own libraries. The package includes its
non-platform runtime dependency closure, including `yamodbus` for the Modbus
plugin. Missing optional OTP dependencies are allowed; missing required dependencies
are not. The Modbus plugin declares `circuits_uart` but uses firmware's exact 1.7.0
native driver; its native payload is never included in the plugin archive.

SDK, Phoenix/LiveView and other supported platform libraries are supplied once by
firmware and checked for compatible/exact versions. Private dependency names and
modules belong to one plugin; conflicting selections fail the firmware build.
Even identical private library copies cannot belong to two plugins. Promote a
compatible shared version into firmware deliberately if multiple plugins need it.
No runtime solver, namespace rewriting or silent deduplication is provided.

Plugins contribute pure BEAM code and ordinary `priv` data. Packaging rejects
native libraries/executables and direct NIF loaders. Native facilities already
supplied by firmware are allowed. Inspection is not proof that arbitrary trusted
code cannot dynamically load outside code; this is not a security sandbox.

## Activation and cleanup

Use `/plugins` to inspect, start and stop plugins; `/plugins/:app` hosts optional
plugin UI. `NervesGate.Plugins.list/0`, `start/1`, `stop/1` and `restart/1` are
administrative domain APIs, not plugin SDK functions.

Artifacts are verified against their retained archives before activation. Cold
activation preloads verified modules, binds a fresh private generation to real OTP
application membership, starts private dependencies and checks optional health.
Commands are serialized in bounded workers while the manager remains responsive.
A deadline/lost reply is an unknown result, not cancellation or permission to retry.

Stop quiesces ownership, closes plugin UI sessions, stops private applications,
drains SDK resources and checks unload/purge. Busy code or uncertain cleanup blocks
reuse rather than forcing purge. Shared firmware libraries and other plugins are
never stopped as private dependencies. Startup health is not equipment reachability.

When firmware no longer contains a saved selected version, it is reported unavailable;
there is no automatic switch to another artifact. Where a new firmware version is
available, explicitly select it (left stopped), then Start. Same-version/different-
digest conflicts are rejected; bump plugin versions when bytes change. Rollback is
possible only while the exact previous verified artifact remains available.

## Optional UI

A plugin can declare `nerves_gate_ui: MyPlugin.UI` in its main OTP application's
environment. It must identify an owned, verified `Phoenix.LiveComponent`. UI plugins
declare compatible LiveView dependencies directly; the core SDK has no web dependency.
No extra web server, router recompilation, scripts or plugin subroutes are required.

Components keep drafts separate and command the plugin's supervised processes.
The gateway's LiveView does not own plugin SDK resources. Static/disconnected pages
never invoke plugin code. The manager tracks actual page PIDs, closes them before
unload and refuses to continue if sessions cannot drain. A manager restart also
closes surviving sessions. Stopped plugins show a host-owned unavailable page.

## Storage and state

Firmware-bundled code runs without an SD card. Enabled intent and immutable artifact
identity are stored in schema-2 `/data/nerves_gate/plugins.term`. Unsupported metadata
is rejected intact, never migrated/reset automatically. Existing application-era
`/data/nerves_gate/apps.term` blocks the cutover until a separately authorized
operator decision; it is not silently adopted or deleted.

Plugin storage remains a separately commissioned ext4 SD mount at `/mnt/plugins`.
`Storage.data_dir/1` requires available storage and a real managed calling process;
there is no silent `/data` fallback. Plugins using files must handle storage errors
and removal.

`Storage.save_config/1`, `restore_config/0` and `delete_config/0` keep one opaque
term per plugin version in `<data dir>/.nerves_gate/config/<version>.term`. Firmware
derives plugin and version from the actual managed caller; a plugin cannot name
another plugin or version. Saves replace the file atomically (a failure leaves the
previous term or none; `{:error, :commit_unknown}` means durability is uncertain).
Restores decode safely and report corrupt files without removing them. Updating a
plugin starts from no configuration; older versions' terms are kept until explicitly
deleted. Stopping, disabling, updating or uninstalling never deletes them. There is
no migration, merging or schema: the plugin owns the term.

The two bundled plugins keep their own configuration volatile and do
not require SD for operation. The platform retains durable subnet cleanup ownership
independently of the subnet plugin's volatile state.

Storage commissioning lives at `/settings/storage`. Use existing ext4 media without
formatting, explicitly authorize formatting, or continue without storage. Formatting
is never automatic. Installed development artifacts and running/unresolved ownership
block destructive setup. Uninstalling a development artifact preserves its data.

## SDK and direct libraries

Pure-BEAM protocol libraries run normally in supervised plugin processes. TCP does
not require an SDK socket wrapper or an exclusive interface lease. Plugins own
protocol/equipment semantics; firmware protects shared infrastructure.

`NervesGateSDK` exposes typed platform observations, caller-owned subscriptions,
data directories, assigned hardware observations and exclusive local-network resources. Its fixed firmware
bridge preserves the actual calling PID. Resource calls require active managed
membership and generation-bound references; UI processes or proxy Tasks cannot
claim resources on a plugin's behalf. Serial/CAN libraries open assigned resources
in supervised plugin workers, not SDK transport proxies. See [hardware](hardware.md).
Internet/USB configuration, enrollment,
credentials, plugin lifecycle and firmware updates remain administrative operations.

## Development artifacts

Local `.ez` package/install tooling remains for disposable-device development and
lifecycle qualification, not product distribution. These immutable SD-backed
artifacts use the same manager, loader and ownership rules; they cannot replace a
firmware-selected plugin. SD identity is checked across installation/activation.
Removal stops development activations; reattachment can restore enabled intent
only after prerequisites and integrity are verified. See [development](plugin-development.md).
