# Nerves Gate

An Ethernet gateway with a local Phoenix LiveView UI, built with Nerves and
ordinary Elixir/OTP. EC100 is the production target; development and integration
checks use a real x86 Nerves backend in QEMU.

## Develop

On a [prepared Linux workstation](docs/development.md#prerequisites):

```sh
mix setup
mix dev.qemu
```

Open **http://localhost:4000**. Setup installs Mix tooling and dependencies,
verifies and installs the x86 Tailscale binary, and builds the local Nerves system.
The first system build can take an hour; reruns reuse its build cache. No physical
device, tailnet enrollment, workstation network changes or Node.js are needed.

Keep `mix dev.qemu` running. In another terminal:

```sh
mix test --only cable_loss       # one scenario; results also appear at /tests
```

The workstation runs only the UI and development tools. Device services run in
QEMU, not hardware simulators. See [development](docs/development.md) for workflow,
all-scenario checks, CI, EC100 development and troubleshooting.

## Use a gateway

Open `http://<gateway-address>:4000` through LAN, USB or Tailscale.

- **Overview** — Internet setup, Tailscale remote access and Erlang distribution.
- **Equipment** — LAN, RS485 and CAN settings and bounded diagnostics.
- **Device** — runtime information, identification and button/LED help.

A new gateway tries DHCP independently on both Ethernet ports. Configure roles
under **Overview → Internet**. First setup through verified USB saves directly;
other changes have a 60-second **Keep changes / Restore previous settings** window.
USB remains independent for recovery.

**There is no UI sign-in protection.** Anyone who can reach port 4000 can change
settings. The distribution page also exposes full VM access credentials. Use
trusted networks and restrictive Tailscale policy; never expose these services to
the public Internet. CSRF and same-origin checks remain enabled.

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
Git history. Set `NERVES_GATE_SSH_KEYS` to authorized public keys at build time;
SSH is key-only. Keep the Nerves startup guard enabled for Heart initialization
and firmware validation.

Before updating, verify device identity, firmware platform and a local recovery
path. Use an in-place firmware update to preserve `/data` and Tailscale identity,
not a full-disk burn. EC100 A/B updates and recovery still require hardware
qualification. See the [x86 system notes](systems/nerves_system_x86_64/GATEWAY.md)
for the test target's deliberate differences.
