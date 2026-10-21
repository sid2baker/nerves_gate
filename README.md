# Nerves Gate

An Ethernet gateway built with Nerves, Phoenix LiveView and ordinary Elixir/OTP,
plus an SDK for trusted OTP applications that run on it. EC100 and the QEMU
development devices run the same firmware and gateway UI.

## Develop the product

On a [prepared Linux workstation](docs/development.md#prerequisites):

```sh
mix setup
mix dev
```

Open **http://localhost:4000** and choose **Start devices**. The simulator site
manages QEMU devices and tests; each device has a tests page at `/devices/:id` and
a link to its gateway UI. Keep `mix dev` running and use another terminal:

```sh
mix test.firmware --only cable_loss --device gateway_a
mix dev.ui gateway_a                       # gateway UI with reload, localhost:4001
mix dev.ui nerves_gate@100.101.102.103      # same UI against a real gateway
mix ci                                     # SDK, simulator, generator and firmware CI
```

Development needs no physical gateway or workstation network changes. See
[development](docs/development.md).

## Write an application

```sh
mix archive.install hex nerves_gate_new
mix nerves_gate.new my_workspace
cd my_workspace
mix setup
mix sim
# Start devices on the site, then choose Application storage → Use this card.
# In another terminal in the workspace:
mix app.install my_app
mix app.new telemetry
mix setup
mix test
mix app.package telemetry
```

The workspace contains one initial app at `apps/my_app/` and can create more
independent apps with `mix app.new`. It owns simulator configuration and tools;
each app depends only on the SDK. This workflow does not require cloning this
repository or building firmware. `mix setup` downloads and checksum-verifies the
pinned QEMU image when missing, without requiring GitHub CLI. Existing images are
preserved. To use custom firmware, select its path in `config/simulator.exs` and
provide the file yourself.

Applications depend only on [`nerves_gate_sdk`](sdk/README.md), run on real
firmware (including the [QEMU simulator](sim/README.md)) and ship as standard OTP
`.ez` archives on the gateway's SD card. See [app development](docs/app-development.md) and the [application runtime](docs/applications.md).

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
CAN/RS485 offer bounded diagnostics and SDK access, not bus bridges. Cellular is
disabled by default.

## Repository

| Project | Package | Purpose |
| --- | --- | --- |
| [`firmware/`](firmware/README.md) | `nerves_gate` | Device application, gateway UI, SDK backend, app runtime |
| [`sdk/`](sdk/README.md) | `nerves_gate_sdk` | Application API and packaging |
| [`sim/`](sim/README.md) | `nerves_gate_sim` | QEMU simulator and scenario runner |
| [`new/`](new/README.md) | `nerves_gate_new` | Application generator |
| `systems/` | `nerves_system_ec100`, `nerves_system_ec100_qemu` | Nerves systems |

Each project is an independent Mix project with its own version, changelog and
namespaced release tags. The root `mix.exs` only orchestrates them.

Guides: [Product development](docs/development.md) · [App development](docs/app-development.md) · [CI](docs/ci.md) · [Releases](docs/releases.md) · [Architecture](docs/architecture.md) ·
[Public API](docs/action-api.md) · [Applications](docs/applications.md) ·
[Networking](docs/networking.md) · [UI](docs/ui.md) ·
[LEDs and button](docs/indicators.md) · [Buses](docs/buses.md).

## Build EC100 firmware

Supply a checksum-verified, executable static ARM `tailscaled` at
`firmware/rootfs_overlay/ec100/usr/sbin/tailscaled`; `mix setup` prepares only
the x86 daemon.

```sh
cd firmware
NERVES_GATE_LOCAL_DEPS=1 MIX_ENV=prod MIX_TARGET=ec100 mix firmware --overwrite
```

Firmware commands run inside `firmware/`, not at the repository root. Use
`MIX_TARGET=x86_64` there for a QEMU firmware build.

All firmware targets share `firmware/mix.lock`. Firmware combines
`rootfs_overlay/common` with the target overlay. Set `SOURCE_DATE_EPOCH` when
building without Git history.

Before updating, verify device identity, firmware platform and recovery access.
Update in place to preserve `/data` and enrollment, and keep the Nerves startup
guard enabled. USB IPv4 SSH accepts `root` with password `nerves_gate`; other
connections need keys managed under **Settings**. See
[recovery access](docs/networking.md#local-recovery-and-http-exposure) and the
[QEMU system notes](systems/nerves_system_ec100_qemu/GATEWAY.md).
