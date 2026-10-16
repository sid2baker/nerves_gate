# Nerves Gate

An Ethernet gateway with a local Phoenix LiveView UI, built with Nerves and
ordinary Elixir/OTP. EC100 is the production target; development and integration
checks use a real x86 Nerves backend in QEMU.

## Develop

On a [prepared Linux workstation](docs/development.md#prerequisites):

```sh
mix setup
mix dev
```

Open **http://localhost:4000/tests** and choose **Start configured devices**.
Phoenix starts immediately with an empty simulator; gateway pages stay disconnected
until bootstrapping finishes. Setup installs Mix tooling and dependencies,
verifies and installs the x86 Tailscale binary, and downloads the prebuilt EC100
QEMU system. Dependencies and application firmware still compile locally, but
Linux and Erlang do not. No Docker, physical device, tailnet enrollment,
workstation network changes or Node.js are needed for normal development.

Keep `mix dev` running. Once the devices are ready, in another terminal:

```sh
mix test --only cable_loss       # one scenario; results also appear at /tests
```

The workstation runs the UI and a separate host-only Simulator BEAM. Start builds
one firmware image and bootstraps two QEMU devices through real USB SSH/fwup updates.
Stop preserves their disks; explicit Reset erases disks and enrollment. Device services run in Nerves, not in-memory mocks.
See [development](docs/development.md) for simulator configuration, workflow,
all-scenario checks, CI, EC100 development and troubleshooting.

## Use a gateway

Open `http://<gateway-address>:4000` through LAN or USB. After Tailscale enrollment,
use `https://<gateway-dns-name>/` (requires tailnet MagicDNS and HTTPS). The gateway
forwards HTTPS port 443 to its local UI; HTTP port 80 is not enabled.

- **Overview** — Internet setup, Tailscale remote access and Erlang distribution.
- **Equipment** — LAN, RS485 and CAN settings and bounded diagnostics.
- **Device** — runtime information, identification and button/LED help.

A new gateway tries DHCP independently on both Ethernet ports. Configure roles
under **Overview → Internet**. First setup through verified USB saves directly;
other changes have a 60-second **Keep changes / Restore previous settings** window.
USB remains independent for recovery.

**There is no UI sign-in protection.** Anyone who can reach port 4000 or the
Tailscale HTTPS endpoint can change settings. The distribution page also exposes
full VM access credentials. Use trusted networks and restrictive Tailscale policy;
never expose these services to the public Internet. HTTP CSRF protection and
session-bound LiveView CSRF validation remain enabled; WebSocket Origin checking
is disabled.

Tailscale manages the gateway and can share a confirmed equipment IPv4 subnet;
overlapping networks are unsupported. CAN/RS485 offer bounded captures and
explicitly authorized Modbus reads, not remote bus bridges. Cellular support is
prepared but disabled until the modem and BSP are qualified. Physical indicators,
recovery and bus behavior have [qualification limits](docs/development.md#coverage-and-limits).
There is no Ethernet DHCP server, Internet sharing or web firmware upload.

## Code and documentation

Start with [`NervesGate`](lib/nerves_gate.ex) for named commands, status queries
and subscriptions. Domains own commands and persistence; the device-owned
projection is only a shared UI read model.

| Guide | Contents |
| --- | --- |
| [Development](docs/development.md) | Setup, QEMU scenarios, troubleshooting and CI |
| [Architecture](docs/architecture.md) | Ownership, supervision and projection flow |
| [Public API](docs/action-api.md) | Calling conventions, results and subscriptions |
| [Networking](docs/networking.md) | Port roles, rollback, Tailscale, Livebook and recovery |
| [UI](docs/ui.md) | Navigation and equipment observations |
| [LEDs and button](docs/indicators.md) | Meanings, gestures and reset safety |
| [Buses](docs/buses.md) | CAN/RS485 diagnostics and qualification |

## Build EC100 firmware

EC100 uses the external system checkout configured in `mix.exs`. Supply a
checksum-verified static ARM `tailscaled` at
`rootfs_overlay/ec100/usr/sbin/tailscaled`, executable. `mix setup` prepares **only
x86**; it never replaces the ARM daemon or modifies the EC100 BSP.

```sh
export MIX_TARGET=ec100
export MIX_ENV=prod
mix deps.get
mix firmware --overwrite
```

All targets share `mix.lock`. Rootfs overlays combine `rootfs_overlay/common` and
the target directory. Firmware builds never download or replace Tailscale; binaries
are ignored by Git. Set `SOURCE_DATE_EPOCH` when building a source archive without
Git history. On USB IPv4, SSH accepts user `root` with password `nerves_gate`,
without a key. Ethernet and Tailscale remain key-only. Add/remove public keys at
**Settings** (`/settings`); optionally seed a new device with build-time
`NERVES_GATE_SSH_KEYS`. Saved keys survive firmware updates. Keep the Nerves
startup guard enabled for Heart initialization and firmware validation.

Before updating, verify device identity, firmware platform and a local recovery
path. Use an in-place firmware update to preserve `/data` and Tailscale identity,
not a full-disk burn. EC100 A/B updates and recovery still require hardware
qualification. See the [x86 system notes](systems/nerves_system_ec100_qemu/GATEWAY.md)
for the test target's deliberate differences.
