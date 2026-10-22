# App development

Start the platform with `mix dev`. No solution manifest, generator archive,
platform fork or environment variables are required.

## Create or open an application

In the workbench's **Applications** panel:

1. On **Applications**, enter a new directory, such as `../my_controller`, and select **Create application**.
2. Or enter an existing Mix project's directory and select **Open application**.
3. Use **Test** and **Package** on its row. Opened directories are remembered for
   this session, not written into platform source.

An app is an ordinary independent Mix project with its own Git repository and
`mix.lock`. It depends on `{:nerves_gate_sdk, "~> 0.1.0"}` plus its private
libraries, and declares an SDK requirement and health check. Tests exercise pure
app decisions over typed observations; real I/O uses QEMU, not a fake host backend.

The equivalent commands from the platform checkout are:

```sh
mix app.new ../my_controller
mix app.test ../my_controller
mix app.package ../my_controller
mix dev ../my_controller
```

`mix dev APP_DIRECTORY` simply opens that app on startup; plain `mix dev` is the
normal entry point. `mix app.new PATH --local-sdk` is for SDK maintainers: it uses
this checkout's SDK instead of Hex. Do not distribute workstation-specific paths.

Packages are written to `APP_DIRECTORY/packages/NAME.ez`. Existing output is not
silently replaced; move/remove it deliberately before rebuilding. App tests and
builds run in supervised separate Mix processes, never loading app code into the
workbench VM. Inside an app, ordinary `mix test` and
`MIX_ENV=prod mix nerves_gate.package` also work.

## Find gateways on the current network

The workbench automatically makes a bounded local mDNS query when opened. Use
**Refresh discovery** to search again. It only lists advertisements identifying
`Nerves Gate`; it does not scan subnets or configure the workstation network/VPN.
The **Add address** form accepts a DNS hostname (including Tailscale DNS) or an
explicit IPv4 address without probing it.

New firmware advertises its public hostname, firmware version and target via
`_nerves-device._tcp`. Already-installed firmware without this advertisement will
not appear automatically: add its known address manually, or explicitly update
it through your authorized firmware procedure. Multicast filtering and VM network
boundaries can prevent discovery.

Advertisement data is unverified, not authentication. **Open gateway** opens the
device's existing HTTP UI on port 4000. That UI has no sign-in: only use it on
trusted networks. Finding a device never attaches simulator drivers, installs an
app or updates firmware. Use the explicit [firmware build/review/update flow](firmware-updates.md) for
physical-device firmware; finding a device never authorizes an update.

## Run an app on QEMU

Start simulated devices explicitly in the workbench. On each guest, open
**Settings → Application storage → Use this card** for its prepared virtual SD
card. Device-owned storage commissioning is not bypassed.

Select a simulated device in the app row and choose **Install on simulator**, or:

```sh
mix app.install ../my_controller --device gateway_a
mix app.console --device gateway_a
```

Installations, scenarios and Manual control share backend reservations. The
console command prints the SSH IEx command only with idle Manual control; close
SSH before releasing it. `RingLogger.attach()` follows device/app logs.

Same-version development reinstall preserves app data; versioned upgrades use
the device's health-checked rollback. Packages never bundle the SDK or platform.

## Install on a physical gateway

This remains an explicit SSH/SFTP procedure with authorized access:

1. Commission a supported card in the gateway's Application storage settings.
2. Package the app and transfer its `.ez` to a temporary file on the gateway.
3. In SSH IEx, call `NervesGate.Apps.install(path)`, then
   `NervesGate.Apps.start(:your_app)`. Use `NervesGate.Apps.upgrade(path)` for a
   versioned update.
4. Remove the temporary file and inspect app status/logs.

Use your own authorized connection and keys. Never copy the simulator's public
development cookie into production. Native dependencies must be built for the
device architecture. See [application lifecycle](applications.md).
