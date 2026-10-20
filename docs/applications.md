# Application runtime

Applications are trusted OTP applications in the firmware's BEAM. They can crash
or block the VM; the SDK is an API boundary, not a security sandbox. There is no
hot-code upgrade or dependency solver.

## Storage

- `/data/nerves_gate/apps.term` contains only each application's enabled flag,
  active version and previous version.
- `/mnt/apps/apps/<app>/<version>/` contains the extracted OTP application
  directories from its `.ez` archive.
- `/mnt/apps/data/<app>/` contains application-owned data.

`/mnt/apps` must be a separately mounted, writable filesystem. `NervesGate.Storage`
checks the Linux mount table; an empty mountpoint on the root filesystem is not
an SD card. It never formats media. With `:nerves_gate, :apps_device` configured,
it mounts that prepared ext4 device (`nodev,nosuid`) and lazily detaches it once
the device disappears. QEMU configures its virtual card, `/dev/vdb`; EC100 leaves
it unset until the physical card path is qualified, so provisioning must mount the
card there (or configure `:apps_mount`). No card is required to boot or administer
the gateway. Storage APIs return
`{:error, :storage_unavailable}` when media is absent. Removal stops managed apps;
reinsertion restores enabled selections. Previously opened file handles cannot
be revoked by an SDK, so applications must handle filesystem errors too.

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
