# Application runtime

Applications are trusted OTP applications in the firmware's BEAM. They can crash
or block the VM; the SDK is an API boundary, not a security sandbox. There is no
hot-code upgrade or dependency solver.

For ordinary SDK app projects and packaging, see [App development](app-development.md).

## Storage

- `/data/nerves_gate/apps.term` is schema 1: enabled intent, active/previous
  selection, committed generation sequence and an immutable artifact catalog with
  SHA-256 and reserved application/module names for every installed version.
- `/mnt/apps/apps/<app>/<version>/package.ez` retains the checked archive;
  `content/` beneath that directory contains its extracted OTP applications.
- `/mnt/apps/data/<app>/` contains application-owned data.

### Commissioning

Open **Application storage** from Settings (`/settings/storage`). Overview links to setup when storage needs attention. No card is
required to commission networking or administer the gateway.

- **No card:** continue without apps; insert a card and return here later.
- **Prepared ext4 card:** choose **Use this card — keep data**. Existing apps and
  data are preserved; nothing is formatted.
- **FAT or unprepared card:** back it up, then choose **Format for applications**
  and explicitly confirm the data-loss warning, or continue without apps.
- **Failure:** the page reports the result and offers retry or skip. Formatting
  may already have erased data even if it fails; never retry blindly.

The choice is saved in `/data/nerves_gate/storage`. A prepared QEMU card also
requires a choice on first commissioning. Once use is selected, compatible cards
mount on insertion and enabled apps are restored. Selecting skip leaves storage
unavailable until the user chooses to use or format a card later.

### Ownership and safety

`NervesGate.Storage` owns detection, setup operations, mounting and the device's
storage projection. Apps owns only application lifecycle and excludes erase/skip
while applications are installed (even stopped apps). Uninstalling apps preserves
their data; formatting does not. Storage setup is administrative, not an SDK API.

`/mnt/apps` must be a separately mounted writable filesystem; an empty directory
on the firmware root is not a card. Platform configuration selects the device:
EC100 uses `/dev/mmcblk1p1`; QEMU uses a prepared 256 MiB virtual disk `/dev/vdb`.
There is no separate target-to-device mapping and callers cannot supply a path.

Insertion never formats media. Explicitly confirmed formatting runs `mke2fs` with
a deadline, creates ext4, then mounts it with `nodev,nosuid`. The backend rechecks
card identity after confirmation and unmounting. Mounted system disks, their
partitions, other mount locations and busy filesystems are rejected. Removal
stops managed apps and detaches the stale mount; apps must still handle errors
on previously opened file handles.

For administrative automation, read the detected card ID, then make a choice:

```elixir
storage = NervesGate.status().storage
NervesGate.Storage.setup(:use, storage.card_id) # preserves data
NervesGate.Storage.setup(:skip)                 # no card required
# Destructive, only after explicit user consent:
NervesGate.Storage.setup(:format, storage.card_id, :erase_all_data)
```

Commands acknowledge admission promptly. Observe `NervesGate.status().storage`
for `operation`, `ready` and `error`; the UI uses the device-owned projection.
A missing formatter is reported without erasing the card.

## Packages

Build with the SDK's `mix nerves_gate.package`. The archive is standard OTP layout,
not a custom package format. Its main `.app` declares the required SDK range in
`:nerves_gate_sdk_requirement` and may declare a health-check MFA in
`:nerves_gate_health_check`. The app template provides both.

The installer checks archive paths, sizes, application specifications, BEAM module
identities, dependencies, SDK compatibility and platform/module conflicts before
adding any code paths. Workbench/platform application and module names are
reserved, including obsolete platform names; those archives cannot be installed.
Code is extracted to a new staging directory and renamed
into place; an installed version is never overwritten. App/module names reserved
by another installed application cannot be reused. Dependencies bundled privately
belong to one application; platform libraries are shared and never stopped by the
application manager. The packager records exact common-library versions in the
ordinary `.app` environment, which the installer checks against firmware.

## Device SDK

Firmware selects `NervesGate.SDKBackend`. It translates network,
identity and storage observations into SDK structs; it does not expose status
maps, distribution settings or administrative commands. Subscribe before querying.
Events describe changes (system uptime and storage are polled once a second).
Stateful SDK calls require a running/starting managed application activation.
Subscriptions, bus I/O and local network leases are fenced by that activation's
private generation, but still belong to the actual calling PID and reference—not
merely an app name. Startup callbacks can acquire resources. Read-only queries
remain available outside managed apps; raw IEx/RPC maintenance uses domain APIs.
Subscribe/claim again after the owner, backend or activation restarts. Never pass
resource calls through a platform Task as a substitute owner.

`NervesGate.Buses` owns both diagnostics and SDK hardware access. `rs485_1` and
`rs485_2` map internally to EC100's qualified automatic-direction 9600 8N1 ports.
A claim excludes other applications and gateway diagnostics. Release or owner
exit closes the UART. Receive data is delivered only to the owner. No arbitrary
Linux path or serial-setting override is accepted.

CAN subscriptions deliver classic CAN frames, not diagnostic maps. Transmit only
works on an already-up interface in normal mode. SDK calls never configure the
interface. An administrator must explicitly configure normal mode, for example:

```elixir
NervesGate.Buses.configure("can0", %{
  "enabled" => true, "bitrate" => 250_000, "listen_only" => false
})
```

Gateway settings default to listen-only; passive diagnostic captures still require
it. SDK sends validate frame bounds and recheck the kernel mode. QEMU without
EC100 bus hardware reports unavailable ports rather than pretending to send.
Applications own equipment discovery, identities, configuration and protocol
sessions. There is no platform equipment registry or compatibility SDK API.

## Administration

These operations are device administration, not SDK functions:

```elixir
NervesGate.Apps.install("/tmp/my_app-1.0.0.ez")
NervesGate.Apps.list()
NervesGate.Apps.start(:my_app)
NervesGate.Apps.stop(:my_app)
NervesGate.Apps.restart(:my_app)
NervesGate.Apps.upgrade("/tmp/my_app-1.1.0.ez")
NervesGate.Apps.rollback(:my_app)
NervesGate.Apps.uninstall(:my_app)
```

Workbench physical installation uses the new-only `Apps.install_new(path, expected)`
owner boundary. It checks the reviewed SHA-256, app/version, SD identity and absence
of any prior installation before extracting the checked bytes. Compiled
`install_review/1` and `install_reviewed/2` provide bounded SSH protocol responses;
no application lifecycle intent or executable source is shipped by the workbench.
Unknown results are never automatically retried. See [physical installation](app-development.md#install-on-a-physical-gateway).

Install registers a disabled application without starting it. An identical
registered archive is idempotent; different bytes for that app/version are rejected.
No installed version, unregistered directory or previous artifact is overwritten
or adopted. Bump the version for a changed development package. App/module names
remain reserved even if an installed artifact is stopped or unreadable.

`Artifact` separates immutable identity from runtime activation. Every start
verifies the retained archive SHA, exact extracted file set/content/modes and BEAM
identities, then loads verified specs and module bytes before OTP startup. Extra
files, symlinks, tampering and loaded-code conflicts fail closed. Artifact files
are read-only; application data is separate and writable. These permissions are
not a security boundary against trusted same-BEAM code.

`Apps` owns one admission slot, protected generation bindings and synced metadata.
A linked loader worker performs bounded effects while list/admission remain
responsive. The lifecycle budget is 180 seconds; the public command waits up to
190 seconds. A caller timeout is not cancellation. Read state before retrying.

Upgrade prepares the candidate before stopping working code, then quiesces the
old generation, stops/drains it, activates and starts the candidate, and runs its
health-check MFA with a five-second deadline. Only `:ok` permits an atomic
selection commit. A commit failure is not success. One checked unload path handles
normal stop, partial activation and rollback: stop private apps in dependency
order, drain SDK resources, unload owned specs/code and remove acquired paths.
Platform dependencies are never stopped or purged.

Every activation attempt, including rollback/restoration, gets a fresh generation.
The previous artifact is reverified before rollback; a previously stopped app stays
stopped. Network cleanup withdraws owned routes before removing addresses. Failed
cleanup, busy old code or uncertain effects leave a blocked state instead of
force-purging unrelated processes or activating conflicting code. Explicit stop
persists disabled intent first. App-manager restart invalidates its epoch and
reconciles owned runtime/resources before restoring enabled selections.

`list/0` returns versions, selection, SHA, committed sequence, phase/running state
and errors, not private epoch tokens, handles, PIDs or paths. Unsupported/corrupt
metadata returns `{:error, :invalid_app_metadata}` and blocks app/storage changes
without taking gateway management down. There is no legacy reader, digest backfill
or automatic migration. Existing installations need a separately authorized
external upgrade/reinstall procedure; never reset saved state just to pass checks.

Preloading executes `@on_load`/NIF initialization, so it is not effect-free.
Health checks should inspect the application's own APIs, not acquire resources
through their platform-supervised Task. Startup/shutdown callbacks must be bounded.
Arbitrary user-code side effects and externally supervised/group-leader-changing
tasks cannot be contained or rolled back by this trusted-runtime lifecycle.

A new package may remain installed after an unsuccessful upgrade, but it is not
selected on reboot. Application data is not rolled back: apps must use a compatible
data schema or manage their own backups before migrations.
