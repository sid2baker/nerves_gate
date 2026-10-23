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
mix app.new ../my_controller      # --local-sdk uses this checkout's SDK
mix app.test ../my_controller
mix app.package ../my_controller
mix dev ../my_controller          # open the app when the workbench starts
```

An app is an independent Mix project with its own repository and `mix.lock`. It
depends on `{:nerves_gate_sdk, "~> 0.1.0"}` and declares an SDK requirement and a
health check (the template provides both). Unit-test pure decisions over typed
observations; test real I/O on QEMU, not with a fake backend.

Packages are written to `APP_DIRECTORY/packages/NAME.ez`; existing output is never
replaced silently. App builds run in separate Mix processes, never in the
workbench VM. Inside the app, `mix test` and `MIX_ENV=prod mix nerves_gate.package`
work as usual.

## Run an app on QEMU

Start simulated devices on the Simulator page. On each device, open
**Settings → Application storage → Use this card** for its virtual SD card. Then
choose **Install on simulator** in the app row, or:

```sh
mix app.install ../my_controller --device gateway_a
mix app.console --device gateway_a   # prints an SSH IEx command during Manual control
```

Installs, scenarios and Manual control share device reservations. In the console,
`RingLogger.attach()` follows logs. A same-version reinstall keeps app data; a new
version uses the device's health-checked upgrade. Packages never bundle the SDK.

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

This is an explicit SSH procedure with your own authorized key:

1. Commission an SD card in the gateway's Application storage settings.
2. Package the app and copy the `.ez` to a temporary file on the gateway.
3. In SSH IEx, run `NervesGate.Apps.install(path)` and
   `NervesGate.Apps.start(:your_app)`, or `NervesGate.Apps.upgrade(path)` for a
   new version.
4. Delete the temporary file and check app status and logs.

Never reuse the simulator's development cookie in production. Native dependencies
must be built for the device architecture. See [application runtime](applications.md).
