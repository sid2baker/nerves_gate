# Plugin development

A plugin is an independent Mix project with its own `mix.lock` and ordinary OTP
supervision tree. The gateway owns infrastructure; plugins own protocols and
equipment semantics. No custom adapter framework or separate web server is needed.

## Selected plugins

`plugins/selection.exs` selects `plugins/tailnet_subrouter` and `plugins/modbus`.
Each project declares its dependencies normally. The Modbus plugin declares
`{:yamodbus, "== 0.1.0"}`; its private library code is bundled with it. Modbus 0.2.0
also declares `circuits_uart` 1.7.0, supplied natively by firmware and never included
in the pure-BEAM plugin archive. LiveView is a
direct dependency only of plugins that provide UI. Keep shared library versions
aligned with firmware. No contributed native libraries, executables or NIFs.

Build firmware from the repository root:

```sh
mix firmware x86_64
mix firmware ec100
```

These commands build assets and isolated plugin projects, validate the whole
selection and generate the firmware inventory before Nerves assembly. They do not
boot or deploy devices. Direct device-project builds require prepared plugin output;
use the root commands to rebuild selection and sources together.

After a separately authorized firmware deployment, open `/plugins`. Start a plugin,
open its page and configure its functionality explicitly. Adding or changing a
plugin requires another firmware build. Changed package bytes require a new version;
there are no same-version replacement or downgrade workarounds.

## Test and package independent projects

```sh
cd plugins/modbus
mix deps.get
mix test
MIX_ENV=prod mix nerves_gate.package --output /tmp/modbus-plugin.ez
```

The Modbus tests use the real yamodbus client against a disposable, supervised
loopback TCP peer and real circuits_uart/yamodbus RTU over disposable PTYs. Install
`socat` for the RTU test suite; missing tools fail explicitly. No equipment is contacted. Pure policy/component tests run on
the host; device lifecycle and SDK ownership qualification use owned QEMU scenarios.
Host success is not runtime/vendor-equipment qualification.

`mix check` includes SDK/firmware/root checks and both plugin test suites. It never
starts QEMU. The `plugins` scenario covers firmware discovery without commissioned
SD, explicit activation, UI cleanup and real Modbus TCP on a disposable QEMU device.
The user owns `mix dev` and device starts; do not launch/reset a bench implicitly.

## Plugin contracts

Declare the SDK dependency and matching `nerves_gate_sdk_requirement` OTP environment
entry. This checkout uses `~> 0.2.0-dev`; use the local SDK path until that version is
published. The runtime checks the declared requirement, not capability probes.

Use the OTP application callback and supervised workers normally. An optional
`nerves_gate_health_check` MFA verifies startup, not external device readiness.
An optional `nerves_gate_ui` module declares a verified LiveComponent. UI commands
must call the plugin's supervised API; the hosting LiveView cannot own SDK claims.
See [runtime](applications.md) for dependency ownership and cleanup guarantees.

Read-only hardware observations can be queried through the SDK. Protocol clients
should use normal libraries/TCP. Claim exclusive shared resources only where needed:
serial/CAN workers open exclusively assigned resources, and local Ethernet addressing
requires an exclusively assigned LAN plus a caller-owned network lease. Query assignments through
`NervesGateSDK.Hardware.resources/0`. Keep transport workers supervised by the plugin. There are no SDK
bus transport proxies. Local-network addressing still uses platform leases; creating
a TCP connection does not claim or reconfigure the Internet interface. See [hardware](hardware.md).

## Disposable development installs

The workbench's application-project tools also support creating/testing/packaging
independent OTP projects and installing development artifacts on commissioned QEMU
storage. `mix app.new`, `app.test`, `app.package` and `app.install` refer to ordinary
OTP development projects, not an app store. Build processes remain isolated from
the workbench VM. Existing immutable output/version conflicts are errors.

Physical development installs require review and typed-address confirmation through
`Workbench.Jobs` on the application page. Transfer uses distribution:
verify device identity, package hash, boot/storage identity and compatibility; confirm
once, install stopped, then inspect state. They cannot replace firmware-owned plugins.
Unknown outcomes are never automatically replayed. Do not use this workflow to bypass
the firmware selection or update the physical gateway without authorization.
