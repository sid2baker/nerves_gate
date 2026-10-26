# App development

Start the platform with `mix dev`. No manifest, generator archive or environment
variables are needed.

## Create or open an application

On the workbench's **Applications** page, enter a new directory such as
`../my_controller` and choose **Create application**, or enter an existing Mix
project and choose **Open application**. Each row has **Test** and **Package**.
Opened directories are remembered for the session only.

The command-line equivalents:

```sh
mix app.new ../my_controller --local-sdk
mix app.test ../my_controller
mix app.package ../my_controller
mix dev ../my_controller          # open the app when the workbench starts
```

An app is an independent Mix project with its own repository and `mix.lock`. It
declares matching `~> 0.2.0-dev` dependency/SDK requirements and a health check.
Use `--local-sdk` until SDK 0.2 is published; otherwise dependency resolution
requires that version from Hex and fails if unavailable. Scaffolding never falls
back to an older SDK. Unit-test pure decisions over typed
observations; test real I/O on QEMU, not with a fake backend.

Packages are written to `APP_DIRECTORY/packages/NAME.ez`; existing output is never
replaced silently. App builds run in separate Mix processes, never in the
workbench VM. Inside the app, `mix test` and `MIX_ENV=prod mix nerves_gate.package`
work as usual.

## Optional starter apps

`apps/tailnet_subrouter` is an ordinary SDK project shipped as source, not a default
service. Open it using **Applications → Open starter app source**, or run
`mix app.test apps/tailnet_subrouter` and `mix app.package apps/tailnet_subrouter`.
Installation/startup are explicit and the app starts disabled. Configure and enable
through its named API; see its [README](../apps/tailnet_subrouter/README.md) for
operator preparation, tailnet approval limitations and incomplete-cleanup recovery.

The SDK local-network API belongs to this checkout's `0.2.0-dev`, not published
0.1.0. The starter requires `~> 0.2.0-dev` and the device installer rejects an
older SDK before installation; there is no runtime capability probe.
Equipment protocols, addressing requirements and polling belong to apps. The gateway
still enforces shared-resource admission and protects Internet/USB management.

## Run an app on QEMU

Start simulated devices on the Simulator page. On each device, open
**Settings → Application storage → Use this card** for its virtual SD card. Then
choose **Install on simulator** in the app row, or:

```sh
mix app.install ../my_controller --device gateway_a
mix app.console --device gateway_a   # prints an SSH IEx command during Manual control
```

Installs, scenarios and Manual control share device reservations. In the console,
`RingLogger.attach()` follows logs. Registered versions are immutable: bump the
version for changed bytes; installation never silently uninstalls/replaces the same
version. A new version uses verified cold upgrade and health-checked rollback.
Packages never bundle the SDK. Stateful SDK calls must originate in the managed
application's own processes, not directly from IEx/RPC.

## Find physical gateways

The Devices page browses local mDNS for `_nerves-device._tcp` advertisements from
Nerves Gate; **Refresh discovery** searches again. It never scans subnets or
changes workstation networking. **Add address** accepts a hostname (including
Tailscale DNS) or IPv4 address for firmware that does not advertise, or across
networks mDNS cannot reach.

Advertisements are unverified. **Open gateway** opens the device's HTTP UI on port
4000, which has no sign-in: use it only on trusted networks. Finding a device never
installs anything; firmware updates follow [their own flow](firmware-updates.md).

## Install on a physical gateway

In `mix dev`, open the application (or **Open starter app source**) and use
**Install on physical device**:

1. Discover/add the physical gateway on Devices and commission an SD card under
   its **Settings → Application storage**. Firmware must support `Apps.install_new/2`.
2. Select the gateway and choose **Review package and device**. The workbench builds
   an immutable private package snapshot, verifies known-host/public-key SSH, reads
   identity/boot/storage and checks SDK/platform requirements. Nothing is uploaded.
3. Inspect application/version, device address/serial, firmware, size and SHA-256.
   Type the exact reviewed hostname/address and confirm. The review expires after
   ten minutes and is consumed once.
4. The workbench rechecks identity, boot, storage and compatibility, uploads once
   with SFTP, verifies the package hash on-device, and installs **stopped and disabled**.
   An existing application is rejected: no replacement, upgrade or restart is implied.

Authentication uses the same strict SSH policy as firmware review: authorized keys,
`SSH_AUTH_SOCK` when present and known_hosts. Unknown/changed hosts, passwords and
interactive trust prompts are not accepted. DNS/Tailscale names and LAN/USB IPv4 work;
independent USB is not required. USB does not bypass host-key authentication.

Installation does not start the app, change firmware, configure hardware or advertise
routes. Start deliberately in the device's trusted SSH IEx console with
`NervesGate.Apps.start(:your_app)`, then configure/enable its use case separately.
If an upload or result is interrupted, inspect installed application/storage state
before a fresh review. Writes are never automatically replayed. Private local
snapshots are cleaned on completion, replacement or expiry; an interrupted transport
can leave a private temporary package on the device, never automatically loaded.

For manual installation or a separately authorized upgrade, copy the packaged `.ez`
to a temporary device file, call `NervesGate.Apps.install(path)` or
`NervesGate.Apps.upgrade(path)` in SSH IEx, and remove the file afterward. These are
administrative APIs, not an alternative automatic fallback for a failed review.

Never reuse the simulator's development cookie in production. Native dependencies
must be built for the device architecture. See [application runtime](applications.md).
