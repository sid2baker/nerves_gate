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
manages devices and tests; each device has a tests page at `/devices/:id` and a
link to its gateway UI. Keep `mix dev` running and use another terminal:

```sh
mix test --only cable_loss --device gateway_a
mix dev.ui gateway_a                       # gateway UI with reload, localhost:4001
mix dev.ui nerves_gate@100.101.102.103      # same UI against a real gateway
```

Development needs no physical gateway or workstation network changes. See
[development](docs/development.md).

## Use a gateway

Open `http://<gateway-address>:4000` over LAN or USB. With Tailscale enrollment,
MagicDNS and HTTPS enabled, use `https://<gateway-dns-name>/`.

- **Overview** — Internet setup, Tailscale and Erlang distribution.
- **Equipment** — LAN, RS485 and CAN settings and diagnostics.
- **Settings** — LAN arrangement, SSH keys and device information.

A new gateway tries DHCP on both Ethernet ports. Choose port roles under
**Overview → Internet**. First setup through verified USB saves directly; other
changes are restored unless kept within 60 seconds. USB stays available for recovery.

**The UI has no sign-in.** Anyone who can reach it can change settings and get
full VM access through the distribution page. Use trusted networks and a
restrictive Tailscale policy. Never expose the UI or distribution ports publicly.

Tailscale can share the equipment IPv4 subnet; overlapping networks are unsupported.
CAN/RS485 offer bounded diagnostics, not bus bridges. Cellular is disabled by default.

## Source layout

```text
lib/
├── nerves_gate.ex       Public API
├── nerves_gate/         Device domains: networking, VPN, SSH, LEDs, buses
└── nerves_gate_web/     Gateway UI

dev/
├── simulator.ex        Simulated device lifecycle
├── simulator/          Virtual hardware and networks
├── simulator_web/      Simulator site
└── mix/tasks/          Development commands

test/
├── scenarios/          QEMU scenarios: cables, reboot, update…
└── support/            Shared runner and device controls

config/                 Workstation and firmware settings
assets/                 CSS and JavaScript sources
priv/static/assets/     Built browser assets
rootfs_overlay/         Extra firmware files
systems/                QEMU system package
```

Guides: [Development](docs/development.md) · [Architecture](docs/architecture.md) ·
[Public API](docs/action-api.md) · [Networking](docs/networking.md) ·
[UI](docs/ui.md) · [LEDs and button](docs/indicators.md) · [Buses](docs/buses.md).

## Build EC100 firmware

The EC100 system is pinned to a release tag in `mix.exs`. Supply a checksum-verified,
executable static ARM `tailscaled` at `rootfs_overlay/ec100/usr/sbin/tailscaled`;
`mix setup` prepares only the x86 daemon.

```sh
MIX_TARGET=ec100 MIX_ENV=prod mix deps.get
MIX_TARGET=ec100 MIX_ENV=prod mix firmware --overwrite
```

All targets share `mix.lock`. Firmware combines `rootfs_overlay/common` with the
target overlay. Set `SOURCE_DATE_EPOCH` when building without Git history.

Before updating, verify device identity, firmware platform and recovery access.
Update in place to preserve `/data` and enrollment, and keep the Nerves startup
guard enabled. USB IPv4 SSH accepts `root` with password `nerves_gate`; other
connections need keys managed under **Settings**. See
[recovery access](docs/networking.md#local-recovery-and-http-exposure) and the
[QEMU system notes](systems/nerves_system_ec100_qemu/GATEWAY.md).
