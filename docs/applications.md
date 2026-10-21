# Application runtime

Applications are trusted OTP applications in the firmware's BEAM. They can crash
or block the VM; the SDK is an API boundary, not a security sandbox. There is no
hot-code upgrade or dependency solver.

## Application development

The app developer uses a generated workspace, not this product repository.
Install the generator from Hex once:

```sh
mix archive.install hex nerves_gate_new
mix nerves_gate.new my_workspace
cd my_workspace
mix setup
```

The workspace starts with one independent application and owns the simulator:

```text
my_workspace/
  mix.exs
  config/simulator.exs
  firmware/                 # prebuilt QEMU image, not product source
  apps/my_app/              # independent SDK application
```

The workspace depends on the simulator and generator tools (`runtime: false`,
development/test only). Each app depends only on `nerves_gate_sdk` and has its
own Mix project, dependency closure, unit tests and deployable package. This is
not an umbrella. Installing the generator does not install QEMU or firmware.

`mix setup` downloads the pinned **x86_64 QEMU firmware image** to
`firmware/nerves_gate.fw` over HTTPS and verifies its SHA-256 checksum. Existing
images are reused without a download; no GitHub CLI is needed. To use custom
firmware, select its path in `config/simulator.exs` and provide that file yourself.
A missing custom path is reported rather than filled with a default image. Then run:

```sh
mix sim
```

On the site, start devices, open a gateway UI and choose
**Application storage → Use this card**. In another terminal in the workspace:

```sh
mix app.install my_app                 # package, install and start on a guest
mix app.new telemetry                 # scaffold a second independent app
mix setup                             # fetch all apps' dependencies
mix test                              # all apps' host unit tests; no devices
mix app.install telemetry --device gateway_a
mix app.package telemetry             # packages/telemetry-1.0.0.ez
mix format                            # workspace and app formatters
```

App selection is optional when only one app exists. With multiple apps, install
and package require a name. `--output path.ez` selects a package destination;
existing files are never overwritten. Installation uses a temporary package.
All commands use native Mix project entry, not subprocess Mix orchestration.

The simulator requires the Linux/QEMU tools described in
[its README](../sim/README.md). Workspace `mix setup` fetches dependencies and
missing default firmware; it does not build firmware, boot devices or format cards. A real gateway
uses the same SDK and package; install its archive through the administrative
application API after commissioning its SD card. Each app also works on its own:
`cd apps/my_app && mix test` or `mix nerves_gate.package`.

Repository-local development of the platform itself is a different workflow:
see [Development](development.md). Firmware builds run from `firmware/`.

## Storage

- `/data/nerves_gate/apps.term` contains only each application's enabled flag,
  active version and previous version.
- `/mnt/apps/apps/<app>/<version>/` contains the extracted OTP application
  directories from its `.ez` archive.
- `/mnt/apps/data/<app>/` contains application-owned data.

### Commissioning

Open **Application storage** from Overview or Settings (`/storage`). No card is
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
NervesGate.storage_setup(:use, storage.card_id) # preserves data
NervesGate.storage_setup(:skip)                 # no card required
# Destructive, only after explicit user consent:
NervesGate.storage_setup(:format, storage.card_id, :erase_all_data)
```

Commands acknowledge admission promptly. Observe `NervesGate.status().storage`
for `operation`, `ready` and `error`; the UI uses the device-owned projection.
A missing formatter is reported without erasing the card.

## Packages

Build with the SDK's `mix nerves_gate.package`. The archive is standard OTP layout,
not a custom package format. Its main `.app` declares the required SDK range in
`:nerves_gate_sdk_requirement` and may declare a health-check MFA in
`:nerves_gate_health_check`. The generator provides both.

The installer checks archive paths, sizes, application specifications, BEAM module
identities, dependencies, SDK compatibility and platform/module conflicts before
adding any code paths. Code is extracted to a new staging directory and renamed
into place; an installed version is never overwritten. App/module names reserved
by another installed application cannot be reused. Dependencies bundled privately
belong to one application; platform libraries are shared and never stopped by the
application manager. The packager records exact common-library versions in the
ordinary `.app` environment, which the installer checks against firmware.

## Device SDK

Firmware selects `NervesGate.SDKBackend`. It translates network, equipment,
identity and storage observations into SDK structs; it does not expose status
maps, distribution settings or administrative commands. Subscribe before querying.
Events describe changes (system uptime and storage are polled once a second).
Subscriptions and serial claims belong to the calling process, not its OTP app;
subscribe/claim again after that process or the backend restarts.

`NervesGate.Buses` owns both diagnostics and SDK hardware access. `rs485_1` and
`rs485_2` map internally to EC100's qualified automatic-direction 9600 8N1 ports.
A claim excludes other applications and gateway diagnostics. Release or owner
exit closes the UART. Receive data is delivered only to the owner. No arbitrary
Linux path or serial-setting override is accepted.

CAN subscriptions deliver classic CAN frames, not diagnostic maps. Transmit only
works on an already-up interface in normal mode. SDK calls never configure the
interface. An administrator must explicitly configure normal mode, for example:

```elixir
NervesGate.bus_configure("can0", %{
  "enabled" => true, "bitrate" => 250_000, "listen_only" => false
})
```

Gateway settings default to listen-only; passive diagnostic captures still require
it. SDK sends validate frame bounds and recheck the kernel mode. QEMU without
EC100 bus hardware reports unavailable ports rather than pretending to send.
Equipment observations are not proof of current reachability; their SDK
`reachable?` field remains false.

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

Install registers a disabled application without starting it. The active and
previous versions are never overwritten; another copy of a version (from a failed
upgrade, or left on the card after `/data` was reset) is replaced. Start adds code
paths, loads OTP specs and starts the application tree. Stop unloads its private
applications/modules and removes their paths. Uninstall preserves application
data. `list/0` returns installed version names, persisted selection, current running
state and the last lifecycle error; it does not expose credentials.

Upgrade validates first, cold-stops the old version, starts the new one and runs
the health-check MFA with a five-second deadline. Only `:ok` commits the new active
selection. Failure unloads the new code and restarts the previously running
version. Explicit rollback performs the same check on the previous version. Health
checks should inspect application readiness without waiting for Internet access.
An application's OTP startup and shutdown callbacks must themselves be bounded;
trusted code can otherwise block application-controller operations.

A new package may remain installed after an unsuccessful upgrade, but it is not
selected on reboot. Application data is not rolled back: apps must use a compatible
data schema or manage their own backups before migrations.
