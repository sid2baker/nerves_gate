# App development

Use a supported Nerves Gate platform checkout for the workbench. Keep the solution
in its own Git repository. No global generator archive, platform fork, umbrella
or platform dependency in the solution is needed.

## Create a solution

From the platform checkout, after `mix setup`:

```sh
mix solution.new ../my_solution
mix app.new controller --solution ../my_solution
mix app.test --solution ../my_solution
mix app.package controller --solution ../my_solution
mix dev ../my_solution
```

```text
my_solution/
  nerves_gate.exs        # platform version, firmware and devices/wiring
  apps/controller/      # ordinary Mix project, its own mix.lock
  packages/             # ignored packaged output
```

Each app depends only on `{:nerves_gate_sdk, "~> 0.1.0"}` plus its private
libraries. It declares an SDK requirement and health check. Tests exercise pure
app decisions over typed SDK observations; real I/O is tested against QEMU.
There is no host hardware backend.

`mix solution.new PATH --local-sdk` is for platform SDK development. Newly created
apps in that solution use this checkout's SDK source instead of Hex. Do not
commit a workstation-specific path as a distributable solution dependency.

`nerves_gate.exs` is trusted executable Elixir data, not a sandbox:

```elixir
%{
  platform: "0.2.0-dev",
  firmware: :local,
  devices: %{gateway_a: %{network: %{internet: :lan1}}}
}
```

`:local` builds x86_64 firmware from the checkout when needed. A compatible `.fw`
path, relative to the solution directory or absolute, can be supplied instead.
The workbench warns about platform-version mismatches. Wiring edits persist in
this file. Opening it starts no devices and builds nothing.

## App commands

Run commands from the platform checkout. Supply `--solution PATH`; when omitted,
the active workbench session's solution is used.

- `mix app.new NAME`: scaffold an independent app; existing files are never replaced.
- `mix app.test [NAME]`: fetch dependencies and test one or all apps.
- `mix app.package [NAME]`: build an immutable `packages/NAME.ez`; select an app
  explicitly when there is more than one. Move/remove an existing local package
  deliberately before rebuilding that same output.
- `mix app.install [NAME] --device gateway_a`: package and submit installation to
  the running session. Inspect live results on the device page.
- `mix app.console --device gateway_a`: print the guest SSH IEx command. Acquire
  idle Manual control first; close SSH before releasing it. Use
  `RingLogger.attach()` for device/application logs.

Solution builds and tests use separate supervised Mix processes. They do not
load app modules or another SDK into the workbench VM. Each app also supports
ordinary `mix test` and `MIX_ENV=prod mix nerves_gate.package` in its own directory.

## Run on QEMU

Start configured devices in the workbench. On each gateway, open **Settings →
Application storage → Use this card** for the prepared virtual SD card. Storage
commissioning is device-owned and is not bypassed by the developer tools.

Use the solution panel to test/package apps and select a device for installation.
The device must be ready and unreserved. App installation, scenarios and Manual
control share the same backend admission. Same-version development reinstall
preserves app data; versioned upgrades use the device's normal health-checked
rollback path. Archives never bundle the SDK or platform runtime.

## Real gateways

The workbench does not flash, provision or update physical devices. Real-gateway
app installation remains an explicit SSH/SFTP procedure with authorized access:

1. Commission a supported card in the gateway's Application storage settings.
2. Package the app and transfer the `.ez` to a temporary file on the gateway.
3. In its SSH IEx console, invoke `NervesGate.Apps.install(path)`, then
   `NervesGate.Apps.start(:your_app)`. Use `NervesGate.Apps.upgrade(path)` for an
   installed app's versioned update.
4. Remove the temporary transfer file and inspect app status/logs.

Use your own authorized device connection and public-key configuration; do not
copy the simulator's public development cookie into production. Native app
dependencies must be built for the device architecture. See
[application lifecycle](applications.md) for trust, storage and rollback details.
