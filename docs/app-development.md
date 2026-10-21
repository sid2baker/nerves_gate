# Application development

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
a versioned file under `firmware/` over HTTPS and verifies its SHA-256 checksum.
Existing managed images are verified again before reuse; mismatched files are
preserved and reported, never overwritten. The generated config calls
`NervesGateNew.Firmware.default_path(__DIR__)`, so updating the generator and
running setup selects its new pinned image without deleting older images.
Older workspaces with a literal `firmware/nerves_gate.fw` path can opt in by using
that expression; literal/custom paths remain developer-owned. No GitHub CLI is needed. To use custom
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
[its README](../sim/README.md). Workspace `mix setup` checks host prerequisites, fetches dependencies and
missing default firmware; it does not build firmware, boot devices or format cards. A real gateway
uses the same SDK and package; install its archive through the administrative
application API after commissioning its SD card. Each app also works on its own:
`cd apps/my_app && mix test` or `mix nerves_gate.package`.

Repository-local development of the platform itself is a different workflow:
see [Development](development.md). Firmware builds run from `firmware/`.


## Host tests and device feedback

The generated app demonstrates pure decisions over SDK-owned structs. Keep SDK
calls in supervised workers and pass observations into pure functions for host
tests. This requires neither a fake backend nor QEMU. SDK operations on the host
without a backend return `{:error, :backend_not_configured}`; integration belongs
on real QEMU firmware.

After installation, acquire **Manual** control on the simulator device page:

```sh
mix app.console --device gateway_a
```

Run the printed SSH command in your terminal. It connects to that owned guest's
USB recovery forward and opens IEx; use the documented USB recovery authentication.
In IEx, `RingLogger.attach()` follows logs and `RingLogger.detach()` stops following.
This is full device access, not an app sandbox. Close SSH before releasing Manual
control. Keep secrets out of logs. This command prints connection information; it
never opens a second simulator or modifies workstation networking.

## Installing on a real gateway

App packages are trusted native OTP code. Until authenticated application
administration exists, there is deliberately no HTTP app upload API. Commission
the removable card through the gateway's storage page first, then use authorized
USB SSH or a provisioned SSH key on a trusted network. Never expose the current
unauthenticated gateway UI to untrusted users.

Copy `packages/my_app-1.0.0.ez` using the SSH SFTP subsystem (for example `sftp
root@<gateway-address>` then `put packages/my_app-1.0.0.ez /tmp/my_app-1.0.0.ez`).
Open the gateway's SSH IEx console and invoke:

```elixir
NervesGate.Apps.install("/tmp/my_app-1.0.0.ez")
NervesGate.Apps.start(:my_app)
```

Inspect the install result before starting; use `upgrade/1` for a new version and
`rollback/1` if necessary. Check package/SDK compatibility and native dependencies
for the real device architecture. Simulation is not qualification of physical
buses, timing, power-loss behaviour or safety interlocks.
