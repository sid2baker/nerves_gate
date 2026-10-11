# Nerves Gate

An Ethernet gateway with a small, local web UI, built with Nerves 2, Jido v3 and
Phoenix LiveView. EC100 is the primary target; x86_64 support is in progress.

## Use it

Open `http://<gateway-address>:4000` through LAN, USB or Tailscale.

- **Gateway** — Internet, equipment and Tailscale status at a glance.
- **Network** — choose an Internet connection and optionally add equipment.
- **Tailscale** — connect the gateway, see its address, rename or disconnect it.

A new gateway tries DHCP on both Ethernet ports independently. It suggests the
only plausible Internet port; it never joins networks or silently reassigns saved
roles. First setup is one form. Equipment and Internet are both optional.

First setup through verified USB saves directly. Other network changes have a
60-second **Keep changes / Restore previous settings** window. USB remains
independent for recovery. Technical details are collapsed until needed.

**This UI has no sign-in protection.** Anyone who can reach port 4000 can change
settings. Use trusted networks and restrict access with your Tailscale policy;
do not expose it to the public Internet. CSRF and same-origin checks remain enabled.

Tailscale connects **the gateway itself**. Equipment subnet routing, permissions,
remote equipment verification, cellular, failover and web firmware upload are not
implemented. This software does not start an Ethernet DHCP server or configure NAT.

See [networking and recovery](docs/networking.md) for addressing, rollback and
Tailscale behavior.

## Backend entry point

**Clients use the stateless `NervesGate.Device` facade.** Domain Jido Actions
validate commands; supervised Network, Remote and Connectivity agents coordinate
workflows. Pure selectors read current domain state without a central state server.

```elixir
alias NervesGate.Device

:ok = Device.subscribe()                 # subscribe before reading
view = Device.projection()
view.actions["network.propose"]          # availability and required parameters

Device.dispatch("remote.configure", %{"hostname" => "my-gateway"})
```

| Action | Parameters | Effect |
| --- | --- | --- |
| `network.validate` | `network` | Validate a draft; no changes |
| `network.propose` | `network` | Apply with automatic rollback |
| `network.confirm` | `trial_id` | Keep that trial |
| `network.cancel` | `trial_id` | Restore saved settings |
| `remote.connect` | `hostname` | Configure the name and begin Tailscale sign-in |
| `remote.configure` | `hostname` | Save the device name |
| `remote.disconnect` | none | Sign out of Tailscale |
| `remote.login_url` | none | Explicitly read the private sign-in URL |

The command path is **Device → domain API → Jido AgentServer / Action → typed
directive → infrastructure runtime**. Draft validation runs a pure Jido Action.
Network trials have a durable decision journal and an independent safety watchdog.
Remote operations run in bounded, owned workers. VintageNet and Tailscale remain
authoritative for their configuration and observations. PropertyTable subscriptions
and Alarmist conditions drive conservative, read-only connectivity rechecks.

LiveViews own drafts and presentation. They subscribe directly to properties and
application facts, then re-read; there is no projection server, durable event log
or replayed command queue.

Jido v3 is pinned to immutable source commits. **Approved dependency exception:**
Jido's v3 Action engine requires Runic internally. NervesGate has no direct Runic
calls or workflows, and introduces no AI dependencies.

See the [action API](docs/action-api.md) for return values and UI mapping, and the
[architecture and migration map](docs/architecture.md) for ownership, lifecycle,
signal delivery and the exact dependency pins.

## Develop

Use Elixir 1.20 and the Erlang/OTP major version required by your Nerves system
(current EC100: OTP 29).

```sh
mix deps.get
mix ci                    # compile, format, tests, Credo, Dialyzer, duplication, architecture
mix phx.server            # http://localhost:4000
```

Host mode simulates Ethernet and Tailscale. It never modifies the workstation's
network or starts its VPN daemon. In IEx, `NervesGate.Network.Host.simulate/1`
changes simulated observations. Host HTTP listens on loopback only.

All browser assets are local and checked in. Rebuild CSS with
`cd assets && npm ci && npm run build`. Node.js is not needed on the device or to
compile firmware.

### Integration checks

These bootstrap isolated runtimes and are deliberately separate from `mix test`:

```sh
scripts/test_bridge.sh
MIX_TARGET=host mix run --no-start test/integration/tailscale_test.exs /absolute/path/to/tailscaled
```

The Linux network check requires user namespaces, `ip`, `brctl`, `ifconfig`,
`udhcpc`, `dnsmasq`, `ping` and `curl`. It creates disposable LAN/USB peers and checks
DHCP discovery, bridging, hotplug, static addresses, port roles, rollback and real
HTTP access. It does not configure the workstation LAN.

The Tailscale check uses a private userspace daemon, temporary identity storage
and a private socket. It does not enroll an account, attach to the workstation
daemon or change kernel routes. It checks cached status, configuration writes and
preservation of omitted preferences against daemon 1.104.1.

Neither check substitutes for a firmware boot or hardware test.

## Build firmware

```sh
export MIX_TARGET=ec100    # or x86_64
export MIX_ENV=prod        # omit development tooling from firmware
mix deps.get
mix firmware --overwrite
```

All targets share `mix.lock`. EC100 uses the local system checkout at
`/home/n0gg1n/Development/Work/ism/dev/nerves_system_ec100`, retaining its bootloader,
GPT and A/B update contract. See [systems/README.md](systems/README.md) for the
unfinished x86 system work.

The rootfs combines `rootfs_overlay/common` with `rootfs_overlay/<target>`. Supply a
checksum-verified static `tailscaled` binary for the selected architecture at
`rootfs_overlay/<target>/usr/sbin/tailscaled`, executable. Binaries are ignored by
Git. The EC100 overlay currently contains official ARM **1.104.1**; keep ARM and
x86 binaries separate. **Builds never download or replace the daemon.** The
library's optional `mix tailscale.install` still defaults to the older 1.102.3.

Target builds take the source timestamp from the latest Git commit. Set
`SOURCE_DATE_EPOCH` explicitly for source archives without Git history. Nerves
2.0.0-pre.4 handles that timestamp natively.

Set `NERVES_GATE_SSH_KEYS` to authorized public keys at build time. SSH is key-only;
serial/SSH IEx loads `/etc/iex.exs` and prints NervesMOTD. Keep the Nerves startup
guard enabled: it supplies Heart's initialization handshake and validates firmware
after the expected OTP applications start, without requiring Internet or setup.

Before an update, verify the device identity, firmware platform, and a local
recovery path. Firmware upgrades should preserve `/data` and Tailscale identity;
do not use a full-disk burn for an in-place update.
