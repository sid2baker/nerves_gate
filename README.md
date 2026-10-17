# Nerves Gate

An Ethernet gateway built with Nerves, Phoenix LiveView and ordinary Elixir/OTP.
EC100 and the QEMU development devices run the same application and gateway UI.

## Develop

On a [prepared Linux workstation](docs/development.md#prerequisites):

```sh
mix setup
mix dev
```

Open **http://localhost:4000** and choose **Start devices**. The simulator site
manages device configuration, lifecycle and tests. Each device has a tests page
at `/devices/:id` and a link to its gateway UI.

Keep `mix dev` running. In another terminal:

```sh
mix test --only cable_loss --device gateway_a
mix dev.ui gateway_a                       # gateway UI with reload, localhost:4001
mix dev.ui nerves_gate@100.101.102.103      # same UI against a real gateway
```

Setup downloads the prebuilt QEMU system. Start builds application firmware once
and bootstraps the configured devices through USB SSH/fwup. Stop preserves disks;
Reset erases disks and enrollment. Independent device tests can run concurrently;
multi-device scenarios reserve the whole bench.

See [development](docs/development.md) for prerequisites, configuration, scenarios
and CI. Normal development needs no physical gateway or workstation network changes.

## Use a gateway

Open `http://<gateway-address>:4000` through LAN or USB. With Tailscale enrollment,
MagicDNS and HTTPS enabled, use `https://<gateway-dns-name>/`.

- **Overview** — Internet setup, Tailscale and Erlang distribution.
- **Equipment** — LAN, RS485 and CAN settings and diagnostics.
- **Settings** — LAN arrangement, SSH keys and device information.

A new gateway tries DHCP on both Ethernet ports. Configure roles under
**Overview → Internet**. First setup through verified USB saves directly; other
changes have a 60-second **Keep changes / Restore previous settings** window.
USB remains available for recovery.

**The UI has no sign-in protection.** Anyone who can reach it can change settings
and obtain full VM access through the distribution page. Use trusted networks and
restrictive Tailscale policy. Never expose the UI or distribution ports publicly.
HTTP and LiveView session-bound CSRF protection are enabled.

Tailscale can share a confirmed equipment IPv4 subnet; overlapping networks are
unsupported. CAN/RS485 provide bounded diagnostics, not remote bus bridges.
Cellular is disabled pending hardware qualification. See the
[coverage limits](docs/development.md#coverage-and-limits).

## Code and documentation

The gateway software and a playground for testing it:

```text
lib/
├── nerves_gate.ex       Public controls for the gateway
├── nerves_gate/         Networking, VPN, SSH and other device logic
└── nerves_gate_web/     Gateway web UI

dev/
├── simulator.ex        Starts and stops simulated devices
├── simulator/          Virtual hardware and networks
├── simulator_web/      Simulator control website
└── mix/tasks/          Development commands

test/
├── scenarios/          Exercises: unplug cables, reboot, update…
└── support/            Shared test runner and device controls

config/                 Workstation and firmware settings
assets/                 CSS and JavaScript sources
priv/static/assets/     Built browser assets
rootfs_overlay/         Extra files included in firmware
systems/                QEMU operating-system package
docs/                   Guides
mix.exs                 Dependencies and build commands
```

QEMU runs the real gateway software. The simulator controls its cables, Internet
and power.

Guides: [Development](docs/development.md) · [Architecture](docs/architecture.md) ·
[Public API](docs/action-api.md) · [Networking](docs/networking.md) ·
[UI](docs/ui.md) · [LEDs and button](docs/indicators.md) · [Buses](docs/buses.md).

## Build EC100 firmware

The EC100 system is pinned to a release tag in `mix.exs`. Supply a checksum-verified,
executable static ARM `tailscaled` at `rootfs_overlay/ec100/usr/sbin/tailscaled`.
`mix setup` prepares only the x86 daemon.

```sh
MIX_TARGET=ec100 MIX_ENV=prod mix deps.get
MIX_TARGET=ec100 MIX_ENV=prod mix firmware --overwrite
```

All targets share `mix.lock`. Rootfs overlays combine `rootfs_overlay/common` and
the target directory. Firmware builds use the supplied Tailscale binary. Set
`SOURCE_DATE_EPOCH` when building a source archive without Git history.

Verify device identity, firmware platform and recovery access before updating.
Use an in-place update to preserve `/data` and enrollment. Keep the Nerves startup
guard enabled. USB IPv4 SSH accepts `root` with password `nerves_gate`; other
connections require keys managed under **Settings**. See
[recovery access](docs/networking.md#local-recovery-and-http-exposure) and the
[QEMU system notes](systems/nerves_system_ec100_qemu/GATEWAY.md).
